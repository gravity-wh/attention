// =====================================================================
//  top_varB.sv —— 方案 B：行融合（row-fused）
//
//  ── 与 varA 只差一个变量 ──────────────────────────────────────────
//  varA 是"分层展开"：先把 256 个 S 全算完存进 sm[256]，再整段 softmax
//  存进 pu[256]，最后整段 P·V。varB 改成**一行走完三段再换行**：
//
//      for i in 0..15:
//          s[i][*]  = Q[i] · Kᵀ        → 只写 16 个 s_row
//          p[i][*]  = softmax(s[i][*]) → 只写 16 个 pu_row
//          y[i][*]  = p[i][*] · V      → 直接写 om[i][*]
//
//  于是 sm[256]（32 bit）和 pu[256]（17 bit）整个消失，只剩 16 深的 s_row /
//  pu_row。lane 数仍是 4，与 varA 相同 —— 所以 varA 与 varB 的差异**只有
//  "全矩阵展开 vs 行融合"这一件事**，这是能把它当成单一变量对比的前提。
//
//  ── 为什么这样做仍然逐位一致 ──────────────────────────────────────
//  关键：softmax 是**按行**定义的（题面明说"Softmax 按行执行"），行与行之间
//  没有数据依赖。所以"先算完所有行再归一"和"每行单独归一"是同一个运算，
//  连浮点/定点的舍入点都一模一样 —— 不是"数学上接近"，是逐位相同。
//
//  ⚠️ 反过来，**在线 softmax（flash attention 的 running max/sum 重标定）不能用**：
//  它把 max 的更新与 exp 的累加交错进行，每一步都要对已累加的部分和重新
//  缩放。那个重标定引入了新的舍入点，结果与"先取 max 再整行 exp"**不逐位
//  相等**，判据会直接打掉。本方案没有碰行内顺序：仍然是
//  max → exp → 求和 → 倒数 → 归一，一步没省。
//
//  ── 三级流水（与 varA 同构，但每级干的活更长）──────────────────────
//    A 级：本行的 QK（16 列 × 4 拍 = 64）+ 取 max（顺带，不额外占拍）
//          + exp（16 拍）              = 80 拍/行
//    B 级：倒数 41 拍（长除法）
//    C 级：归一 16 拍 + P·V（16 列 × 4 拍 = 64）= 80 拍/行
//    稳态 = max(80, 41, 80) = 80 拍/行，16 行 ≈ 1400 拍
//    （对比：varA 是 QK 1024 + softmax 704 + PV 1152 ≈ 2855 拍）
//
//  ── 时序（周期数，估）──────────────────────────────────────────────
//    计算 ≈ 1400拍 + 输出 256 = 1660 拍 @100MHz ≈ 16.6us
//    ref 9665 / varA 2855 / varB 1660
// =====================================================================
`include "attn_ports.svh"

module top_varB `ATTN_TOP_PORTS;

  import attn_pkg::*;
  `include "attn_math.svh"

  // ---- 派生常数（与 ref / varA 逐字相同）----
  localparam int QB   = Q_BITS;
  localparam int QF   = Q_FRAC;
  localparam int NL   = 4;
  localparam int NG   = N / NL;
  localparam int PW   = 2 * QB;
  localparam int SH_S = 2*Q_FRAC + 2 - S_FRAC;
  localparam int SH_P = RECIP_SH - P_FRAC;
  localparam int SH_Y = P_FRAC + Q_FRAC - Y_FRAC;

  // ---------------------------------------------------------------- 存储
  // 输入矩阵三份 + 输出一份，三个方案都一样，谁也省不掉。
  logic signed [QB-1:0] qm [0:NELEM-1];
  logic signed [QB-1:0] km [0:NELEM-1];
  logic signed [QB-1:0] vm [0:NELEM-1];
  logic        [15:0]   om [0:NELEM-1];

  // 行局部：这就是行融合省下来的地方（varA 这里是 256 深的 sm / pu）
  logic signed [31:0] s_row  [0:N-1];       // 当前 A 级的 s，F=S_FRAC
  logic        [16:0] pu_row [0:N-1];       // 当前 C 级的 p，F=P_FRAC
  logic [N-1:0]       nzrow_r;              // 当前 C 级的 p 非零掩码
  logic        [16:0] erow   [0:1][0:N-1];  // 双缓冲：A 写 / C 读

  // ---------------------------------------------------------------- 主状态
  // ⚠️ 状态名只是标签：varB 把 QK / softmax / P·V 熔进一条行流水，
  //    没有哪个单独的 state_t 能对应，这里统一用 S_QK 表示"行流水在跑"。
  state_t st;
  logic [7:0] cout;

  // ---------------------------------------------------------------- A 级
  logic        a_busy;
  logic        a_ph;              // 0=QK（顺带取 max），1=exp
  logic [4:0]  a_row;             // 0..16
  logic [3:0]  a_j;               // QK / exp 的列号
  logic [1:0]  a_g;               // QK 的 lane 组号
  logic [1:0]  a_bank;
  logic signed [31:0] a_maxv;
  logic [20:0]  a_tsum;
  logic signed [63:0] a_acc;

  logic        a2b_v;
  logic [20:0]  a2b_t;
  logic [4:0]   a2b_r;
  logic [1:0]   a2b_b;

  // ---------------------------------------------------------------- B 级
  logic        b_busy;
  logic [4:0]  b_row;
  logic [1:0]  b_bank;
  logic        b2c_v;
  logic [24:0] b2c_r;
  logic [4:0]  b2c_row;
  logic [1:0]  b2c_b;

  // ---------------------------------------------------------------- C 级
  logic        c_busy;
  logic        c_ph;              // 0=归一，1=P·V
  logic [4:0]  c_row;
  logic [3:0]  c_j;
  logic [1:0]  c_bank;
  logic [24:0] c_rval;
  logic signed [63:0] c_acc;
  logic        pv_first;
  logic [1:0]  pv_done;

  logic [1:0]  bank_busy;
  logic [4:0]  nfin;
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

  logic [20:0] b_tsum_latch;
  logic [24:0] r_out;
  logic        rcp_busy, rcp_done;
  recip_unit u_rcp (
    .clk(clk), .rst_n(rst_n),
    .start(div_start), .t_sum(b_tsum_latch),
    .r_out(r_out), .busy(rcp_busy), .done(rcp_done)
  );

  // ---------------------------------------------------------------- A 级通路
  logic [7:0] qa_base, kb_base;
  logic signed [PW-1:0] qk_p [0:NL-1];
  logic signed [63:0]   qk_sum;

  assign qa_base = {a_row[3:0], a_g, 2'b00};
  assign kb_base = {a_j,        a_g, 2'b00};

  assign qk_p[0] = $signed(qm[qa_base      ]) * $signed(km[kb_base      ]);
  assign qk_p[1] = $signed(qm[qa_base + 8'd1]) * $signed(km[kb_base + 8'd1]);
  assign qk_p[2] = $signed(qm[qa_base + 8'd2]) * $signed(km[kb_base + 8'd2]);
  assign qk_p[3] = $signed(qm[qa_base + 8'd3]) * $signed(km[kb_base + 8'd3]);
  assign qk_sum  = qk_p[0] + qk_p[1] + qk_p[2] + qk_p[3];

  logic signed [31:0] s_new;
  assign s_new = attn_rne_shift(a_acc + qk_sum, SH_S);

  // ---------------------------------------------------------------- C 级通路
  // P·V 的组调度（与 varA 同一套：按 4 个一组跳过整组为 0 的）
  logic [3:0] gmask;
  always_comb for (int g = 0; g < NG; g++) gmask[g] = |nzrow_r[g*4 +: 4];

  function automatic int ffs_ge(input logic [3:0] gm, input int lo);
    for (int t = 0; t < NG; t++)
      if (t >= lo && gm[t]) return t;
    return -1;
  endfunction

  int          pg;
  logic        pv_have;
  logic [1:0]  pv_g;
  int          pg2;
  logic        pv_last;

  always_comb begin
    pg       = pv_first ? ffs_ge(gmask, 0) : ffs_ge(gmask, int'(pv_done) + 1);
    pv_have  = (pg >= 0);
    pv_g     = pv_have ? 2'(pg) : 2'd0;
    pg2      = pv_have ? ffs_ge(gmask, pg + 1) : -1;
    pv_last  = (pg2 < 0);
  end

  logic [3:0] pu_base;
  logic [7:0] vb_base;
  logic signed [17+QB-1:0] pv_p [0:NL-1];
  logic signed [63:0]      pv_sum;

  assign pu_base = {pv_g, 2'b00};
  assign vb_base = {pv_g, 2'b00, c_j};

  assign pv_p[0] = $signed({1'b0, pu_row[pu_base      ]}) * $signed(vm[vb_base         ]);
  assign pv_p[1] = $signed({1'b0, pu_row[pu_base + 4'd1]}) * $signed(vm[vb_base + 8'd16 ]);
  assign pv_p[2] = $signed({1'b0, pu_row[pu_base + 4'd2]}) * $signed(vm[vb_base + 8'd32 ]);
  assign pv_p[3] = $signed({1'b0, pu_row[pu_base + 4'd3]}) * $signed(vm[vb_base + 8'd48 ]);
  assign pv_sum  = pv_p[0] + pv_p[1] + pv_p[2] + pv_p[3];

  logic signed [63:0] pv_eff;
  assign pv_eff = pv_have ? pv_sum : 64'sd0;
  assign y_fx   = attn_rne_shift(c_acc + pv_eff, SH_Y);

  // ---- softmax 的组合通路 ----
  assign d_fx = a_maxv - s_row[a_j];

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
      cout      <= 8'd0;
      bank_busy <= 2'b00;
      a_busy    <= 1'b0; a_ph <= 1'b0; a_row <= 5'd0; a_j <= 4'd0; a_g <= 2'd0;
      a_bank    <= 2'd0; a_maxv <= 32'sd0; a_tsum <= 21'd0; a_acc <= 64'sd0;
      a2b_v     <= 1'b0; a2b_t <= 21'd0; a2b_r <= 5'd0; a2b_b <= 2'd0;
      b_busy    <= 1'b0; b_row <= 5'd0; b_bank <= 2'd0; b_tsum_latch <= 21'd0;
      b2c_v     <= 1'b0; b2c_r <= 25'd0; b2c_row <= 5'd0; b2c_b <= 2'd0;
      c_busy    <= 1'b0; c_ph <= 1'b0; c_row <= 5'd0; c_j <= 4'd0;
      c_bank    <= 2'd0; c_rval <= 25'd0; c_acc <= 64'sd0;
      pv_first  <= 1'b1; pv_done <= 2'd0;
      nfin      <= 5'd0; div_start <= 1'b0;
      busy      <= 1'b0; done <= 1'b0;
      o_vld     <= 1'b0; o_addr <= 8'd0; o_data <= 16'd0;
    end else begin
      done      <= 1'b0;
      div_start <= 1'b0;

      // ================================================================
      //  行流水：三级并行，只在 st == S_QK 期间推进
      // ================================================================
      if (st == S_QK) begin
        // ---- A 级：本行 QK（顺带取 max）→ exp ----
        if (!a_busy) begin
          if (a_row < N && !(bank_busy[0] && bank_busy[1])) begin
            a_busy <= 1'b1;
            a_ph   <= 1'b0;
            a_j    <= 4'd0;
            a_g    <= 2'd0;
            a_acc  <= 64'sd0;
            a_bank <= bank_busy[0] ? 2'd1 : 2'd0;
            if (bank_busy[0]) begin bank_busy[1] <= 1'b1; end
            else              begin bank_busy[0] <= 1'b1; end
          end
        end else if (a_ph == 1'b0) begin
          // 一个 (i,j) 的 16 项点积，4 lane → 4 拍；最后一拍顺手存 s 并更新 max
          if (a_g == NG-1) begin
            s_row[a_j] <= s_new;
            if (a_j == 4'd0)                 a_maxv <= s_new;
            else if (s_new > a_maxv)         a_maxv <= s_new;
            a_acc <= 64'sd0;
            a_g   <= 2'd0;
            if (a_j == N-1) begin
              a_j    <= 4'd0;
              a_ph   <= 1'b1;
              a_tsum <= 21'd0;
            end else begin
              a_j <= a_j + 4'd1;
            end
          end else begin
            a_acc <= a_acc + qk_sum;
            a_g   <= a_g + 2'd1;
          end
        end else begin
          // 逐元素 exp + 行和（d = max - s，语义与 ref 完全一致）
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

        // ---- B 级：倒数 ----
        if (!b_busy) begin
          if (a2b_v) begin
            b_busy       <= 1'b1;
            b_row        <= a2b_r;
            b_bank       <= a2b_b;
            b_tsum_latch <= a2b_t;
            div_start    <= 1'b1;
            a2b_v        <= 1'b0;
          end
        end else if (rcp_done) begin
          b_busy  <= 1'b0;
          b2c_v   <= 1'b1;
          b2c_r   <= r_out;
          b2c_row <= b_row;
          b2c_b   <= b_bank;
        end

        // ---- C 级：归一 → P·V ----
        if (!c_busy) begin
          if (b2c_v) begin
            c_busy  <= 1'b1;
            c_ph    <= 1'b0;
            c_row   <= b2c_row;
            c_bank  <= b2c_b;
            c_rval  <= b2c_r;
            c_j     <= 4'd0;
            b2c_v   <= 1'b0;
          end
        end else if (c_ph == 1'b0) begin
          pu_row[c_j]      <= p_sat;
          nzrow_r[c_j]     <= |p_sat;
          if (c_j == N-1) begin
            c_ph     <= 1'b1;
            c_j      <= 4'd0;
            c_acc    <= 64'sd0;
            pv_first <= 1'b1;
            pv_done  <= 2'd0;
          end else begin
            c_j <= c_j + 4'd1;
          end
        end else begin
          if (pv_have && !pv_last) begin
            c_acc   <= c_acc + pv_sum;
            pv_done <= pv_g;
            pv_first <= 1'b0;
          end else begin
            om[{c_row[3:0], c_j}] <= y_fp;
            c_acc    <= 64'sd0;
            pv_first <= 1'b1;
            pv_done  <= 2'd0;
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
      end

      // ================================================================
      //  主状态机
      // ================================================================
      case (st)
        S_IDLE: begin
          o_vld <= 1'b0;
          if (start) begin
            busy      <= 1'b1;
            cout      <= 8'd0;
            bank_busy <= 2'b00;
            a_busy <= 1'b0; a_ph <= 1'b0; a_row <= 5'd0; a_j <= 4'd0; a_g <= 2'd0;
            a_acc  <= 64'sd0; a2b_v <= 1'b0;
            b_busy <= 1'b0; b2c_v <= 1'b0; c_busy <= 1'b0; c_ph <= 1'b0;
            nfin   <= 5'd0;
            st     <= S_QK;
          end
        end

        S_QK: begin
          if (nfin == N) begin
            cout <= 8'd0;
            done <= 1'b1;
            st   <= S_OUT;
          end
        end

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
