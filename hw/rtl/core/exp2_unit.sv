// =====================================================================
//  exp2_unit.sv —— 2^(-d) 的 LUT + 线性插值（d >= 0，F = S_FRAC）
//
//  逐位对应 model/attn_model.c 的 exp2_neg()。
//
//  ── 思路来源 ────────────────────────────────────────────────────────
//  参考论文（28nm 27.5TOPS/W 那篇）的 LUT-based softmax unit 与
//  "近似计算只花在小量上"的观点：softmax 里 d 越大 e 越接近 0，
//  对结果的贡献可以忽略，没必要为此付精确 exp 的代价。
//  于是把 exp 拆成「整数部分走移位（免费）+ 小数部分走 16 段表」：
//
//      t = d * log2(e)          (F=16)          ← 一个常数乘法
//      n = t[31:16]  , f = t[15:0]
//      n >= 16  →  直接 0     （2^-16 = 1.5e-5，已低于输出 FP16 的分辨率）
//      idx = f[15:12] (EXP_LUT_BITS 位)          ← 16 段 + 1 端点
//      e = (A[idx] + (A[idx+1]-A[idx]) * rem / 2^(16-b)) * 2^(-n)
//
//  精度：相对误差 < 1.2e-4（a=6 的段最差），对 0.06 的 RMSE 判据有 500 倍余量。
//
//  ── 为什么这里可以"近似"，乘法器却不行 ──────────────────────────────
//  逐位一致的比对对象就是这个近似本身。exp 的近似方式已经写进模型，
//  RTL 只要照抄就一致；而 MAC 一旦做截断近似，累加结果就会漂，
//  「与自身软件模型逐位一致」直接失效。所以近似只能放在模型允许的这三个点：
//  exp、倒数、以及 Q/K/V 的量化。其余一律精确。
// =====================================================================
module exp2_unit (
  input  logic signed [31:0] d_fx,   // d = m - S >= 0，F = S_FRAC
  output logic        [16:0] e_fx    // 2^(-d)，F = 16，范围 [0, 65536]
);

  import attn_pkg::*;
  `include "attn_math.svh"

  localparam int FB     = 16 - EXP_LUT_BITS;   // 插值余量位宽（b=4 → 12）
  localparam int STRIDE = 5 - EXP_LUT_BITS;    // 从 1/32 表抽稀的步长（b=4 → 1）

  logic signed [63:0] t;
  int                 n;
  logic        [15:0] f;
  int                 idx;
  logic        [FB-1:0] rem;
  logic        [16:0] a;
  logic        [16:0] b;
  logic signed [17:0] diff;
  logic signed [63:0] corr;
  logic signed [63:0] e2s;
  logic signed [63:0] e64;

  always_comb begin
    // ---- 1. t = d * log2(e)，F=S_FRAC → F=16（RNE）----
    if (d_fx < 0)  t = 64'sd0;                      // 防御：契约保证 d>=0
    else           t = attn_rne_shift($signed({{32{d_fx[31]}}, d_fx}) * 64'sd94548, 16);

    n = int'(t >>> 16);
    f = t[15:0];

    // ---- 2. 查表 + 线性插值 ----
    idx  = int'(f >> FB);
    rem  = f[FB-1:0];
    a    = attn_exp2_lut(idx << STRIDE);
    b    = attn_exp2_lut((idx + 1) << STRIDE);

    // b - a 一定是负的（表单调下降），必须按有符号算；
    // 注意 rem 是 unsigned，混进来会把乘积变成无符号，这里显式补 0 转 signed。
    diff = $signed({1'b0, b}) - $signed({1'b0, a});
    corr = attn_rne_shift($signed(diff) * $signed({1'b0, rem}), FB);
    e2s  = $signed({47'd0, a}) + corr;

    // ---- 3. 乘 2^(-n)：n 大到位宽之外直接归零 ----
    if (n >= EXP_ZERO_N) begin
      e_fx = 17'd0;
    end else begin
      e64  = attn_rne_shift(e2s, n);
      e_fx = e64[16:0];
    end
  end

endmodule
