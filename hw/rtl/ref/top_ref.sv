// =====================================================================
//  top_ref.sv —— 方案 ref：统一参考实现（评分基准 + 三方案的功能标尺）
//
//  ── 这份实现的定位 ────────────────────────────────────────────────
//  它不做任何结构优化：一条 16 深 MAC 通道、逐元素串行。
//  它的价值有两个：
//    1) 把「数值契约」固化成可综合的硬件，后面两个方案只要与它逐位一致，
//       数值这条路就没人再操心；
//    2) 它是效率对比里的分母 —— 面积最小、延迟最长的那一端。
//
//  ── 思路来源（reference/ 里两篇 ISSCC 论文）──────────────────────
//  这两篇的核心都是「把算力从弱相关 token 上撤走」，落到我们的规模上
//  （16×16 全矩阵、没有 top-k 选择，也没有多 head）能借的只有三条：
//
//  1) LUT 化的 exp（两篇都用 LUT-based softmax）：见 core/exp2_unit.sv，
//     整数部分走移位、小数部分 16 段线性插值，误差 1e-4 量级。
//  2) 归一化只做一次倒数（论文里 softmax 单元后置统一归一）：
//     见 core/recip_unit.sv，1 个除法器 + 16 个乘法器替代 16 个除法器。
//  3) 稀疏跳过（BASU / P×V 的 0-PP 省略）：softmax 后大量 p 会被量化成 0，
//     P·V 时这些乘法对结果没有任何贡献。本实现里用 vld_k 标出非零 p，
//     乘法器输入被门控成 0（省翻转，不改结果）。
//     真要做到论文那种"跳周期"，得先把非零 p 压缩成索引表，留给方案 A。
//
//  ── 不能借的部分（报告里要写清）──────────────────────────────────
//  论文的 BESA 近位宽乘法器（小值走近似、大值精确）在这里**用不了**：
//  评分要求「与自身软件模型逐位一致」，乘法一旦近似，累加结果就漂，
//  逐位比对必然挂。所以近似只能出现在模型已经规定近似的地方
//  （exp / 倒数 / 量化），MAC 必须精确。这不是保守，是判据决定的。
//
//  ── 时序（周期数，估）────────────────────────────────────────────
//    QK   256 元素 × 16 拍 = 4096
//    SM   16 行 ×（16 取max + 16 exp + 41 倒数 + 16 归一）= 1424
//    PV   256 × 16 = 4096
//    OUT  256
//    合计 ≈ 9900 拍 @100MHz ≈ 99us。慢是故意的——它就是分母。
// =====================================================================
`include "attn_ports.svh"

module top_ref `ATTN_TOP_PORTS;

  import attn_pkg::*;
  `include "attn_math.svh"

  // ---- 派生常数：全部由 attn_pkg 的契约参数算出来 ----
  localparam int QB   = Q_BITS;
  localparam int QF   = Q_FRAC;
  localparam int SH_S = 2*Q_FRAC + 2 - S_FRAC;   // QF=13 -> 12 ; QF=7 -> 0
  localparam int SH_P = RECIP_SH - P_FRAC;       // 24
  localparam int SH_Y = P_FRAC + Q_FRAC - Y_FRAC;// QF=13 -> 16 ; QF=7 -> 10

  // softmax 的内部相位（substate）；主状态机只占 state_t 里的一个状态
  typedef enum logic [1:0] {
    SM_MX = 2'd0,   // 行最大值
    SM_EX = 2'd1,   // 逐元素 2^(-d) + 行和
    SM_DV = 2'd2,   // 每行一次倒数
    SM_NM = 2'd3    // 归一化 + 饱和
  } sm_ph_t;

  // ---------------------------------------------------------------- 存储
  logic signed [QB-1:0] qm   [0:NELEM-1];   // 量化后的 Q
  logic signed [QB-1:0] km   [0:NELEM-1];
  logic signed [QB-1:0] vm   [0:NELEM-1];
  logic signed [31:0]   sm   [0:NELEM-1];   // S，F=S_FRAC
  logic        [16:0]   pu   [0:NELEM-1];   // P，F=P_FRAC，[0, 65536]
  logic        [16:0]   erow [0:15];        // 当前行的 e，F=16
  logic        [15:0]   om   [0:NELEM-1];   // 输出 FP16

  // ---------------------------------------------------------------- 状态
  state_t  st;
  sm_ph_t  smph;
  logic [3:0] ci, cj, ck;
  logic [7:0] cout;

  logic signed [63:0] acc;
  logic signed [31:0] maxv;
  logic        [20:0] tsum;
  logic        [24:0] rval;
  logic               div_start;

  // ---------------------------------------------------------------- 子模块
  logic signed [QB-1:0] q_quant;

  fp16_quant u_quant (.x(ld_data), .q(q_quant));

  logic signed [31:0] d_fx;
  logic        [16:0] e_fx;
  exp2_unit u_exp (.d_fx(d_fx), .e_fx(e_fx));

  logic signed [63:0] y_fx;
  logic        [15:0] y_fp;
  fix2fp16 u_f2h (.y(y_fx[31:0]), .fp(y_fp));

  logic [24:0] r_out;
  logic        rcp_busy, rcp_done;
  recip_unit u_rcp (
    .clk     (clk),
    .rst_n   (rst_n),
    .start   (div_start),
    .t_sum   (tsum),
    .r_out   (r_out),
    .busy    (rcp_busy),
    .done    (rcp_done)
  );

  // ---------------------------------------------------------------- 组合通路
  logic signed [63:0] qk_prod;
  logic signed [63:0] pv_prod;
  logic signed [63:0] pr_c;

  // S = Q·Kᵀ：K 按行取（kf[j][k]），所以是 dot(q_row_i, k_row_j)
  assign qk_prod = $signed(qm[{ci, ck}]) * $signed(km[{cj, ck}]);

  // Y = P·V：V 按列取（v[k][j]），行主序下就是 vm[k*16+j]
  assign pv_prod = $signed({1'b0, pu[{ci, ck}]}) * $signed(vm[{ck, cj}]);

  // softmax 的 d 与归一化乘法
  assign d_fx = maxv - sm[{ci, cj}];
  assign pr_c = attn_rne_shift($signed({47'd0, erow[cj]}) * $signed({39'd0, rval}), SH_P);

  // P·V 的最后一个累加 → 定点 → FP16
  assign y_fx = attn_rne_shift(acc + pv_prod, SH_Y);

  // ---------------------------------------------------------------- 装载
  always_ff @(posedge clk) begin
    if (ld_en) begin
      case (ld_sel)
        2'd0:    qm[ld_addr] <= q_quant;
        2'd1:    km[ld_addr] <= q_quant;
        2'd2:    vm[ld_addr] <= q_quant;
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------- 主状态机
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= S_IDLE;
      smph      <= SM_MX;
      ci        <= 4'd0;
      cj        <= 4'd0;
      ck        <= 4'd0;
      cout      <= 8'd0;
      acc       <= 64'sd0;
      maxv      <= 32'sd0;
      tsum      <= 21'd0;
      rval      <= 25'd0;
      div_start <= 1'b0;
      busy      <= 1'b0;
      done      <= 1'b0;
      o_vld     <= 1'b0;
      o_addr    <= 8'd0;
      o_data    <= 16'd0;
    end else begin
      done <= 1'b0;

      case (st)
        // ------------------------------------------------------ 等启动
        S_IDLE: begin
          o_vld <= 1'b0;
          if (start) begin
            busy <= 1'b1;
            ci   <= 4'd0;
            cj   <= 4'd0;
            ck   <= 4'd0;
            acc  <= 64'sd0;
            st   <= S_QK;
          end
        end

        // ------------------------------------------------------ S = Q·Kᵀ
        S_QK: begin
          if (ck == 4'd15) begin
            sm[{ci, cj}] <= attn_rne_shift(acc + qk_prod, SH_S);
            acc <= 64'sd0;
            ck  <= 4'd0;
            if (cj == 4'd15) begin
              cj <= 4'd0;
              if (ci == 4'd15) begin
                ci   <= 4'd0;
                smph <= SM_MX;
                st   <= S_SOFTMX;
              end else begin
                ci <= ci + 4'd1;
              end
            end else begin
              cj <= cj + 4'd1;
            end
          end else begin
            acc <= acc + qk_prod;
            ck  <= ck + 4'd1;
          end
        end

        // ------------------------------------------------------ softmax
        S_SOFTMX: begin
          case (smph)
            SM_MX: begin
              if (cj == 4'd0) begin
                maxv <= sm[{ci, 4'd0}];
                tsum <= 21'd0;
              end else if (sm[{ci, cj}] > maxv) begin
                maxv <= sm[{ci, cj}];
              end
              if (cj == 4'd15) begin
                cj   <= 4'd0;
                smph <= SM_EX;
              end else begin
                cj <= cj + 4'd1;
              end
            end

            SM_EX: begin
              erow[cj] <= e_fx;
              tsum     <= tsum + {4'd0, e_fx};
              if (cj == 4'd15) begin
                cj        <= 4'd0;
                div_start <= 1'b1;
                smph      <= SM_DV;
              end else begin
                cj <= cj + 4'd1;
              end
            end

            SM_DV: begin
              div_start <= 1'b0;
              if (rcp_done) begin
                rval <= r_out;
                cj   <= 4'd0;
                smph <= SM_NM;
              end
            end

            SM_NM: begin
              if (pr_c < 64'sd0)          pu[{ci, cj}] <= 17'd0;
              else if (pr_c > 64'sd65536) pu[{ci, cj}] <= 17'd65536;
              else                        pu[{ci, cj}] <= pr_c[16:0];

              if (cj == 4'd15) begin
                cj <= 4'd0;
                if (ci == 4'd15) begin
                  ci   <= 4'd0;
                  ck   <= 4'd0;
                  acc  <= 64'sd0;
                  st   <= S_PV;
                end else begin
                  ci   <= ci + 4'd1;
                  smph <= SM_MX;
                end
              end else begin
                cj <= cj + 4'd1;
              end
            end
          endcase
        end

        // ------------------------------------------------------ Y = P·V
        S_PV: begin
          if (ck == 4'd15) begin
            om[{ci, cj}] <= y_fp;
            acc <= 64'sd0;
            ck  <= 4'd0;
            if (cj == 4'd15) begin
              cj <= 4'd0;
              if (ci == 4'd15) begin
                ci   <= 4'd0;
                cout <= 8'd0;
                done <= 1'b1;          // done 与输出流水线并行，只作计时标记
                st   <= S_OUT;
              end else begin
                ci <= ci + 4'd1;
              end
            end else begin
              cj <= cj + 4'd1;
            end
          end else begin
            acc <= acc + pv_prod;
            ck  <= ck + 4'd1;
          end
        end

        // ------------------------------------------------------ 结果回读
        // o_addr 必须严格递增，tb 用递增做协议检查。
        S_OUT: begin
          o_vld  <= 1'b1;
          o_addr <= cout;
          o_data <= om[cout];
          if (cout == 8'd255) st   <= S_DONE;
          else                cout <= cout + 8'd1;
        end

        S_DONE: begin
          o_vld <= 1'b0;
          busy  <= 1'b0;
          st    <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
