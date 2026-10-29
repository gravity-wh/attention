// =====================================================================
//  fp16_quant.sv —— FP16 → s(Q_BITS).Q_FRAC 量化（RNE + 饱和）
//
//  逐位对应 model/attn_model.c 的 quant_to_fx()：
//      iv = nearbyint(x * 2^QF)      （RNE）
//      clamp 到 [-(2^(QB-1)), 2^(QB-1)-1]
//
//  ── 算法 ────────────────────────────────────────────────────────────
//   FP16 的值可以精确写成  sig * 2^p：
//      次正规 (e=0)   : sig = mant          , p = -24 + QF
//      正规   (e>0)   : sig = {1'b1, mant}  , p = e - 25 + QF
//   所以「乘 2^QF」在硬件里只是**改移位量**，不需要乘法器：
//      p >= 0 : 左移（精确，不会舍入）
//      p <  0 : 右移 + RNE
//   最后按符号取负、饱和到 QB 位。
//   以 QF=13 为例，p ∈ [-11, 18]，中间量最大 2^29，一个 32 位通道足够。
//
//  这是整个设计里唯一"进数据"的量化点：装载时做一次，之后全程定点。
// =====================================================================
module fp16_quant (
  input  attn_pkg::fp16_t                     x,
  output logic signed [attn_pkg::Q_BITS-1:0]  q
);

  import attn_pkg::*;
  `include "attn_math.svh"

  logic        sgn;
  logic [4:0]  ex;
  logic [9:0]  mant;
  logic [11:0] sig;
  int          sh;
  logic signed [63:0] mag;
  logic signed [63:0] val;

  always_comb begin
    sgn  = x[15];
    ex   = x[14:10];
    mant = x[9:0];

    if (ex == 5'd0) begin
      sig = {1'b0, mant};             // 次正规：mant * 2^-24
      sh  = -24 + Q_FRAC;
    end else begin
      sig = {1'b1, mant};             // 正规：(1024+mant) * 2^(e-25)
      sh  = int'(ex) - 25 + Q_FRAC;
    end

    if (sh >= 0)
      mag = $signed({52'd0, sig}) <<< sh;          // 左移不产生舍入
    else
      mag = attn_rne_shift($signed({52'd0, sig}), -sh);

    val = sgn ? -mag : mag;
    q   = attn_sat(val, Q_BITS);
  end

endmodule
