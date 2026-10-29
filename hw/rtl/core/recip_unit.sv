// =====================================================================
//  recip_unit.sv —— 每行一次倒数：R = RNE(2^40 / T)
//
//  逐位对应 model/attn_model.c 里 softmax 的
//      R = fx_rne_div((int64_t)1 << RECIP_SHIFT, T);
//
//  ── 为什么是"一次倒数 + 16 次乘法"而不是 16 次除法 ──────────────────
//  softmax 要算 p_i = e_i / T。直接做就是 16 个除法器；改写成
//      R = 2^40 / T        （每行 1 次，41 拍）
//      p_i = e_i * R >> 24 （16 个 17×25 乘法器）
//  面积上是「1 个 41 位除法器」换「16 个除法器」，延迟上每行多付 41 拍。
//  参考论文的 softmax 单元也是这条路（归一化放在后级统一做）。
//
//  ── 实现：恢复余数法长除法 ──────────────────────────────────────────
//  被除数固定 2^40（只有最高位是 1），除数 T ∈ [2^16, 2^20]，
//  所以商 <= 2^24，25 位就够。40+1 = 41 拍出商，再 1 拍做 RNE 修正。
//  比直接用 "/" 运算符好：可综合、时序可预期，且舍入方式自己掌握。
// =====================================================================
module recip_unit (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         start,
  input  logic [20:0]  t_sum,    // T，保证 >= 2^16（最大元素 d=0 → e=65536）
  output logic [24:0]  r_out,    // RNE(2^40 / T)
  output logic         busy,
  output logic         done
);

  localparam int NQ = 41;        // 商的位数 = 被除数的位数
  // 注意：不能写 6'd(NQ-1) —— 带位宽的立即数后面接括号在 SV 里是非法字符。
  // 用一条 6 位的 localparam 承接，既保留可读性也不会踩语法。
  localparam logic [5:0] CNT_LAST = NQ - 1;

  logic [5:0]  cnt;              // 0..40
  logic [1:0]  ph;               // 0=除, 1=舍入, 2=交回
  logic [22:0] rem;
  logic [40:0] quo;

  wire [22:0] den  = {2'b0, t_sum};
  // 被除数 2^40 只有第 40 位为 1：第 0 拍移入 1，其余移入 0
  wire [22:0] rsh  = {rem[21:0], (cnt == 6'd0)};
  wire        ge   = (rsh >= den);
  wire [22:0] rsub = rsh - den;
  wire [22:0] rkeep= rsh;

  // 2*rem 与 den 比较，决定是否进位（round-half-to-even）
  wire [23:0] two_rem = {rem, 1'b0};
  wire [23:0] den_x2  = {1'b0, den};
  wire        rnd_up  = (two_rem > den_x2) || ((two_rem == den_x2) && quo[0]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt   <= 6'd0;
      ph    <= 2'd0;
      rem   <= 23'd0;
      quo   <= 41'd0;
      busy  <= 1'b0;
      done  <= 1'b0;
      r_out <= 25'd0;
    end else begin
      done <= 1'b0;
      case (ph)
        // ---------------------------------------------------- 长除法主体
        2'd0: begin
          if (!busy) begin
            if (start) begin
              busy <= 1'b1;
              cnt  <= 6'd0;
              rem  <= 23'd0;
              quo  <= 41'd0;
            end
          end else begin
            if (ge) begin
              rem <= rsub;
              quo <= {quo[39:0], 1'b1};
            end else begin
              rem <= rkeep;
              quo <= {quo[39:0], 1'b0};
            end
            if (cnt == CNT_LAST) ph  <= 2'd1;
            else                 cnt <= cnt + 6'd1;
          end
        end

        // ---------------------------------------------------- RNE 修正
        2'd1: begin
          if (t_sum == 21'd0) r_out <= 25'd0;            // 防御：除零
          else                r_out <= rnd_up ? (quo[24:0] + 25'd1) : quo[24:0];
          busy <= 1'b0;
          done <= 1'b1;
          ph   <= 2'd2;
        end

        // ---------------------------------------------------- 交回一拍
        2'd2: ph <= 2'd0;

        default: ph <= 2'd0;
      endcase
    end
  end

endmodule
