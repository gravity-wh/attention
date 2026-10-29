// =====================================================================
//  top_varA.sv —— 方案 A：适度并行（4 lane）+ 稀疏跳过 + softmax 流水
//
//  ── 与 ref 的关系 ──────────────────────────────────────────────────
//  ref 是"一条 16 深 MAC 通道、逐元素串行"。varA 保持**完全相同的数值语义**
//  （同一套定点格式、同一个 exp2 LUT、同一个倒数算法），只改三处编排：
//
//  1) 4 lane 并行点积（对应论文的"操作数并行"）
//     QK：一次算 4 个乘积再累加，一个 (i,j) 从 16 拍降到 4 拍。
//     ⚠️ 为什么这样改还是逐位一致：所有乘积是**精确整数**（QB 位 × QB 位），
//        64 位累加器全程不溢出，整数加法可结合 —— 换分组顺序，和不变；
//        舍入只在最后一次 attn_rne_shift 上做一次。所以重排是安全的。
//        （这条不成立的前提是累加器溢出或中途舍入，两者这里都没有。）
//
//  2) 稀疏跳过（对应论文 BASU / P·V 的 0-PP 省略）
//     softmax 之后，差值大的那些 p 会被 RNE 舍成 0，它们对 Y 没有任何贡献。
//     ref 只是把乘法器输入门控成 0（省翻转、不省拍）；varA 真正**跳周期**：
//     归一化时顺手记下每行的非零掩码 nzrow，P·V 时按 4 个一组跳过整组零。
//     跳过不改变结果（加 0），所以逐位一致性不受影响。
//
//  3) softmax 三级流水（A: max+exp → B: 倒数 → C: 归一化）
//     倒数那 41 拍是 softmax 的大头，ref 里它整段空等。varA 让 B 级做除法时，
//     A 级同时算下一行的 max+exp（32 拍 < 41 拍，藏得下）。
//     代价是 erow 需要一个 2 bank 的双缓冲（A 写 / C 读），共 2×16×17 bit。
//     稳态从 89 拍/行降到 41 拍/行。
//     ⚠️ 每行内部仍是"先取 max 再 exp 再倒数再归一"，一行也没改顺序，
//        所以与 ref 逐位一致；这是能流水的前提，不是流水的结果。
//
//  ── 仍然不能借的部分 ──────────────────────────────────────────────
//  BESA 那类近似乘法器依旧不能用（逐位一致判据禁止 MAC 近似），理由见
//  rtl/ref/top_ref.sv 文件头。在线 softmax（flash attention 那套 running
//  max/sum 重标定）也**不能用**：它数学上等价但**不逐位等价**，会把判据打掉。
//  本方案的加速全部来自"同样的数，换顺序/换并行度/跳过零"，不含任何近似。
//
//  ── 时序（周期数，估）──────────────────────────────────────────────
//    QK    256 × 4                    = 1024   （ref 4096）
//    SM    16 + 15×41 + 16            ≈  704   （ref 1424）
//    PV    256 × (非零组数, 最多 4)     ≈ 1280   （ref 4096，稀疏时更少）
//    OUT   256
//    合计 ≈ 3300 拍 @100MHz ≈ 33us（ref 9665 拍）
// =====================================================================
`include "attn_ports.svh"

module top_varA `ATTN_TOP_PORTS;

  import attn_pkg::*;
  `include "attn_math.svh"

  // ---- 派生常数（与 ref 逐字相同，不许各自算一套）----
  localparam int QB   = Q_BITS;
  localparam int QF   = Q_FRAC;
  localparam int NL   = 4;                        // lane 数
  localparam int NG   = N / NL;                   // 每组 lane 覆盖的组数 = 4
  localparam int PW   = 2 * QB;                   // 单个乘积位宽
  localparam int SH_S = 2*Q_FRAC + 2 - S_FRAC;
  localparam int SH_P = RECIP_SH - P_FRAC;
  localparam int SH_Y = P_FRAC + Q_FRAC - Y_FRAC;

  // ---------------------------------------------------------------- 存储
  logic signed [QB-1:0] qm   [0:NELEM-1];   // 量化后的 Q / K / V
  logic signed [QB-1:0] km   [0:NELEM-1];
  logic signed [QB-1:0] vm   [0:NELEM-1];
  logic signed [31:0]   sm   [0:NELEM-1];   // S，F=S_FRAC
  logic        [16:0]   pu   [0:NELEM-1];   // P，F=P_FRAC，[0, 65536]
  logic        [15:0]   om   [0:NELEM-1];   // 输出 FP16
  logic [N-1:0]         nzrow [0:N-1];      // 每行 p 的非零掩码，供 P·V 跳组
  logic        [16:0]   erow [0:1][0:N-1];  // 双缓冲：A 级写 / C 级读

  // ---------------------------------------------------------------- 主状态
  state_t  st;
  logic [3:0] ci, cj;
  logic [1:0] cg;                 // QK 的当前组
  logic [7:0] cout;
  logic signed [63:0] acc;

  // P·V 的组游标：pv_first=1 表示当前 (ci,cj) 还没处理任何组
  logic        pv_first;
  logic [1:0]  pv_done;

  // ---------------------------------------------------------------- softmax 流水
  logic [1:0]  bank_busy;         // erow 的两个 bank 是否被占用

  logic        a_busy;
  logic        a_ph;              // 0=取 max，1=exp
  logic [4:0]  a_row;             // 0..16（16 表示全部排完，避免 4bit 回绕）
  logic [3:0]  a_j;
  logic [1:0]  a_bank;
  logic signed [31:0] a_maxv;
  logic [20:0]  a_tsum;

  logic        a2b_v;
  logic [20:0]  a2b_t;
  logic [4:0]   a2b_r;
  logic [1:0]   a2b_b;

  logic        b_busy;
  logic [4:0]  b_row;
  logic [1:0]  b_bank;

  logic        b2c_v;
  logic [24:0] b2c_r;
  logic [4:0]  b2c_row;
  logic [1:0]  b2c_b;

  logic        c_busy;
  logic [4:0]  c_row;
  logic [3:0]  c_j;
  logic [1:0]  c_bank;
  logic [24:0] c_rval;

  logic [4:0]  nfin;              // 已归一化行数，到 N 即 softmax 完成
  logic        div_start;

  // ---------------------------------------------------------------- 子模块
  logic signed [QB-1:0] q_quant;
  fp16_quant u_quant (.x(ld_data), .q(q_quant));

  logic signed [31:0] d_fx;
  logic        [16:0] e_fx;
  exp2_unit u_exp (.d_fx(d_fx), .e_fx(e_fx));

  logic signed [63:0] y_fx;
  logic        [15:0] y_fp;
  fix2fp16 u_f2h (.y(y_fx[31:0]), .fp(y_fp));

  logic [20:0] b_tsum_latch;      // 除法器的被除数锁存（必须先声明，再连端口）
  logic [24:0] r_out;
  logic        rcp_busy, rcp_done;
  recip_unit u_rcp (
    .clk(clk), .rst_n(rst_n),
    .start(div_start), .t_sum(b_tsum_latch),
    .r_out(r_out), .busy(rcp_busy), .done(rcp_done)
  );

  // ---------------------------------------------------------------- 组合通路
  // QK：一次 4 个乘积。乘积宽度显式收窄到 PW，避免综合出 64×64 乘法器。
  logic [7:0] qa_base, kb_base;
  logic signed [PW-1:0] qk_p [0:NL-1];
  logic signed [63:0]   qk_sum;

  assign qa_base = {ci, cg, 2'b00};
  assign kb_base = {cj, cg, 2'b00};

  assign qk_p[0] = $signed(qm[qa_base      ]) * $signed(km[kb_base      ]);
  assign qk_p[1] = $signed(qm[qa_base + 8'd1]) * $signed(km[kb_base + 8'd1]);
  assign qk_p[2] = $signed(qm[qa_base + 8'd2]) * $signed(km[kb_base + 8'd2]);
  assign qk_p[3] = $signed(qm[qa_base + 8'd3]) * $signed(km[kb_base + 8'd3]);
  assign qk_sum  = qk_p[0] + qk_p[1] + qk_p[2] + qk_p[3];

  // ---- P·V 的组调度：找"下一个非零组"，跳过整组为 0 的 ----
  // 必须先于下面的 pv_p 声明：pv_g 是它们的取指下标。
  logic [3:0] gmask;
  always_comb for (int g = 0; g < NG; g++) gmask[g] = |nzrow[ci][g*4 +: 4];

  // 返回 >= lo 的第一个置位组号；没有则返回 -1
  function automatic int ffs_ge(input logic [3:0] gm, input int lo);
    for (int t = 0; t < NG; t++)
      if (t >= lo && gm[t]) return t;
    return -1;
  endfunction

  int          pg;          // 本拍要处理的组，-1 = 没有
  logic        pv_have;
  logic [1:0]  pv_g;
  int          pg2;         // 再下一个非零组，-1 = 本组是最后一个
  logic        pv_last;

  always_comb begin
    pg       = pv_first ? ffs_ge(gmask, 0) : ffs_ge(gmask, int'(pv_done) + 1);
    pv_have  = (pg >= 0);
    pv_g     = pv_have ? 2'(pg) : 2'd0;
    pg2      = pv_have ? ffs_ge(gmask, pg + 1) : -1;
    pv_last  = (pg2 < 0);
  end

  // PV：一次 4 个乘积。pu 按 {ci, g, dd} 取，vm 按 {g, dd, cj} 取。
  // vm 的下标是 k*16+j = {g, dd, cj}，所以 lane 步长是 16 而不是 1。
  logic [7:0] pa_base, vb_base;
  logic signed [17+QB-1:0] pv_p [0:NL-1];
  logic signed [63:0]      pv_sum;

  assign pa_base = {ci, pv_g, 2'b00};
  assign vb_base = {pv_g, 2'b00, cj};

  assign pv_p[0] = $signed({1'b0, pu[pa_base      ]}) * $signed(vm[vb_base         ]);
  assign pv_p[1] = $signed({1'b0, pu[pa_base + 8'd1]}) * $signed(vm[vb_base + 8'd16 ]);
  assign pv_p[2] = $signed({1'b0, pu[pa_base + 8'd2]}) * $signed(vm[vb_base + 8'd32 ]);
  assign pv_p[3] = $signed({1'b0, pu[pa_base + 8'd3]}) * $signed(vm[vb_base + 8'd48 ]);
  assign pv_sum  = pv_p[0] + pv_p[1] + pv_p[2] + pv_p[3];

  // 组全零时 pv_sum 的组号被拉到 0，可能取到非零的 p，必须门控掉
  logic signed [63:0] pv_eff;
  assign pv_eff = pv_have ? pv_sum : 64'sd0;
  assign y_fx   = attn_rne_shift(acc + pv_eff, SH_Y);

  // ---- softmax ----
  assign d_fx = a_maxv - sm[{a_row[3:0], a_j}];

  logic signed [63:0] pr_c;
  logic        [16:0] p_sat;
  assign pr_c = attn_rne_shift($signed({47'd0, erow[c_bank][c_j]}) * $signed({39'd0, c_rval}), SH_P);
  always_comb begin
    if      (pr_c < 64'sd0)     p_sat = 17'd0;
    else if (pr_c > 64'sd65536) p_sat = 17'd65536;
    else                        p_sat = pr_c[16:0];
  end

  // ---------------------------------------------------------------- 装载
  always_ff @(posedge clk) begin
    if (ld_en) begin
      case (ld_sel)
        2'd0: qm[ld_addr] <= q_quant;
        2'd1: km[ld_addr] <= q_quant;
        2'd2: vm[ld_addr] <= q_quant;
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------- 状态机
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= S_IDLE;
      ci        <= 4'd0;  cj     <= 4'd0;  cg    <= 2'd0;  cout <= 8'd0;
      acc       <= 64'sd0;
      pv_first  <= 1'b1;  pv_done <= 2'd0;
      bank_busy <= 2'b00;
      a_busy    <= 1'b0;  a_ph   <= 1'b0;  a_row <= 5'd0;  a_j  <= 4'd0;
      a_bank    <= 2'd0;  a_maxv <= 32'sd0; a_tsum <= 21'd0;
      a2b_v     <= 1'b0;  a2b_t  <= 21'd0;  a2b_r <= 5'd0;  a2b_b <= 2'd0;
      b_busy    <= 1'b0;  b_row  <= 5'd0;  b_bank <= 2'd0; b_tsum_latch <= 21'd0;
      b2c_v     <= 1'b0;  b2c_r  <= 25'd0; b2c_row <= 5'd0; b2c_b <= 2'd0;
      c_busy    <= 1'b0;  c_row  <= 5'd0;  c_j    <= 4'd0; c_bank <= 2'd0;
      c_rval    <= 25'd0;
      nfin      <= 5'd0;  div_start <= 1'b0;
      busy      <= 1'b0;  done   <= 1'b0;
      o_vld     <= 1'b0;  o_addr <= 8'd0;  o_data <= 16'd0;
    end else begin
      done      <= 1'b0;
      div_start <= 1'b0;

      // ================================================================
      //  softmax 三级流水：只在 S_SOFTMX 期间推进
      // ================================================================
      if (st == S_SOFTMX) begin
        // ---- A 级：max + exp ----
        if (!a_busy) begin
          if (a_row < N && !(bank_busy[0] && bank_busy[1])) begin
            a_busy <= 1'b1;
            a_ph   <= 1'b0;
            a_j    <= 4'd0;
            a_bank <= bank_busy[0] ? 2'd1 : 2'd0;
            if (bank_busy[0]) begin bank_busy[1] <= 1'b1; end
            else              begin bank_busy[0] <= 1'b1; end
          end
        end else if (a_ph == 1'b0) begin
          // 取行最大值
          if (a_j == 4'd0)                     a_maxv <= sm[{a_row[3:0], 4'd0}];
          else if (sm[{a_row[3:0], a_j}] > a_maxv) a_maxv <= sm[{a_row[3:0], a_j}];
          if (a_j == N-1) begin
            a_j    <= 4'd0;
            a_ph   <= 1'b1;
            a_tsum <= 21'd0;
          end else begin
            a_j <= a_j + 4'd1;
          end
        end else begin
          // 逐元素 exp + 行和
          erow[a_bank][a_j] <= e_fx;
          a_tsum            <= a_tsum + {4'd0, e_fx};
          if (a_j == N-1) begin
            a_busy <= 1'b0;
            a_row  <= a_row + 5'd1;
            a2b_v  <= 1'b1;
            a2b_t  <= a_tsum + {4'd0, e_fx};
            a2b_r  <= a_row;
            a2b_b  <= a_bank;
          end else begin
            a_j <= a_j + 4'd1;
          end
        end

        // ---- B 级：倒数（41 拍，长除法）----
        if (!b_busy) begin
          if (a2b_v) begin
            b_busy        <= 1'b1;
            b_row         <= a2b_r;
            b_bank        <= a2b_b;
            b_tsum_latch  <= a2b_t;
            div_start     <= 1'b1;
            a2b_v         <= 1'b0;
          end
        end else if (rcp_done) begin
          b_busy  <= 1'b0;
          b2c_v   <= 1'b1;
          b2c_r   <= r_out;
          b2c_row <= b_row;
          b2c_b   <= b_bank;
        end

        // ---- C 级：归一化 + 记非零掩码 ----
        if (!c_busy) begin
          if (b2c_v) begin
            c_busy <= 1'b1;
            c_row  <= b2c_row;
            c_bank <= b2c_b;
            c_rval <= b2c_r;
            c_j    <= 4'd0;
            b2c_v  <= 1'b0;
          end
        end else begin
          pu[{c_row[3:0], c_j}]     <= p_sat;
          nzrow[c_row[3:0]][c_j]    <= |p_sat;
          if (c_j == N-1) begin
            c_busy <= 1'b0;
            c_row  <= c_row + 5'd1;
            nfin   <= nfin + 5'd1;
            if (c_bank == 2'd0) bank_busy[0] <= 1'b0;
            else                bank_busy[1] <= 1'b0;
          end else begin
            c_j <= c_j + 4'd1;
          end
        end
      end

      // ================================================================
      //  主状态机
      // ================================================================
      case (st)
        S_IDLE: begin
          o_vld <= 1'b0;
          if (start) begin
            busy     <= 1'b1;
            ci       <= 4'd0; cj <= 4'd0; cg <= 2'd0; cout <= 8'd0;
            acc      <= 64'sd0;
            pv_first <= 1'b1; pv_done <= 2'd0;
            bank_busy <= 2'b00;
            a_busy <= 1'b0; a_ph <= 1'b0; a_row <= 5'd0; a_j <= 4'd0;
            a2b_v  <= 1'b0;
            b_busy <= 1'b0; b2c_v <= 1'b0; c_busy <= 1'b0;
            nfin   <= 5'd0;
            st     <= S_QK;
          end
        end

        // ------------------------------------------------ S = Q·Kᵀ
        S_QK: begin
          if (cg == NG-1) begin
            sm[{ci, cj}] <= attn_rne_shift(acc + qk_sum, SH_S);
            acc <= 64'sd0;
            cg  <= 2'd0;
            if (cj == N-1) begin
              cj <= 4'd0;
              if (ci == N-1) begin
                ci <= 4'd0;
                st <= S_SOFTMX;
              end else begin
                ci <= ci + 4'd1;
              end
            end else begin
              cj <= cj + 4'd1;
            end
          end else begin
            acc <= acc + qk_sum;
            cg  <= cg + 2'd1;
          end
        end

        // ------------------------------------------------ softmax
        S_SOFTMX: begin
          if (nfin == N) begin
            ci       <= 4'd0; cj <= 4'd0;
            acc      <= 64'sd0;
            pv_first <= 1'b1; pv_done <= 2'd0;
            st       <= S_PV;
          end
        end

        // ------------------------------------------------ Y = P·V
        S_PV: begin
          if (pv_have && !pv_last) begin
            acc     <= acc + pv_sum;
            pv_done <= pv_g;
            pv_first <= 1'b0;
          end else begin
            om[{ci, cj}] <= y_fp;
            acc      <= 64'sd0;
            pv_first <= 1'b1;
            pv_done  <= 2'd0;
            if (cj == N-1) begin
              cj <= 4'd0;
              if (ci == N-1) begin
                ci   <= 4'd0;
                cout <= 8'd0;
                done <= 1'b1;
                st   <= S_OUT;
              end else begin
                ci <= ci + 4'd1;
              end
            end else begin
              cj <= cj + 4'd1;
            end
          end
        end

        // ------------------------------------------------ 结果回读
        S_OUT: begin
          o_vld  <= 1'b1;
          o_addr <= cout;
          o_data <= om[cout];
          if (cout == 8'd255) st <= S_DONE;
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
