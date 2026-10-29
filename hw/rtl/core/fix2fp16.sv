// =====================================================================
//  fix2fp16.sv —— 定点中间值 → FP16（RNE）
//
//  逐位对应 model/attn_model.c 里的
//      out->y[i][j] = d_to_f16(ldexp((double)y, -Y_FRAC));
//
//  也就是说：把整数 y 当成 y * 2^(-Y_FRAC) 这个精确值，按 RNE 舍入成 FP16。
//
//  ── 为什么不用"通用 double→FP16 转换器" ─────────────────────────────
//  这里的输入是**整数**，它有两条很强的性质，能把电路砍到最小：
//    1) 非零的 |y| >= 1，所以值 >= 2^-13 > 2^-14 —— 永远落在 FP16 正规区，
//       次正规/下溢分支根本不会走到（C 侧那段分支是给通用输入兜底用的）。
//    2) 尾数只需要"取最高位往下 11 位 + RNE"，不需要对阶、不需要
//       sticky 位的长链，因为低位就是精确的。
//  于是：找最高位（优先编码器）→ 取 11 位 → 舍入 → 尾数进位回填指数。
//
//  以 Y_FRAC=13 为例：FP16 的指数域 E = p - Y_FRAC + 15 = p + 2（p 为 msb 位号）。
// =====================================================================
module fix2fp16 #(
  parameter int FRAC = attn_pkg::Y_FRAC
)(
  input  logic signed [31:0] y,     // 定点值，F = FRAC
  output logic        [15:0] fp     // FP16 位模式
);

  logic        sgn;
  logic [31:0] a;
  int          p;
  int          sh;
  logic [31:0] q;
  logic [31:0] r;
  logic [31:0] half;
  int          expf;
  logic [9:0]  mant;

  always_comb begin
    sgn = y[31];
    a   = sgn ? (~y + 32'd1) : y;        // |y|

    // ---- 找最高有效位（优先编码器）----
    p = 0;
    for (int k = 0; k < 31; k++)
      if (a[k]) p = k;

    expf = p - FRAC + 15;
    q    = a;
    r    = 32'd0;

    if (a == 32'd0) begin
      fp = 16'h0000;                      // ±0
    end else if (p <= 10) begin
      // 位数够，直接左对齐到尾数，无舍入
      q    = a <<< (10 - p);
      mant = q[9:0];
      fp   = (expf >= 31) ? {sgn, 5'h1F, 10'd0} : {sgn, expf[4:0], mant};
    end else begin
      // 需要右移 p-10 位并 RNE
      sh   = p - 10;
      q    = a >>> sh;
      r    = a & ((32'd1 << sh) - 32'd1);
      half = 32'd1 << (sh - 1);
      if (r > half || (r == half && q[0])) q = q + 32'd1;
      if (q == 32'd2048) begin            // 尾数进位：1024 → 指数 +1
        q = 32'd1024;
        expf = expf + 1;
      end
      mant = q[9:0];
      fp   = (expf >= 31) ? {sgn, 5'h1F, 10'd0} : {sgn, expf[4:0], mant};
    end
  end

endmodule
