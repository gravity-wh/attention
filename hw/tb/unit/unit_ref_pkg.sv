// =====================================================================
//  unit_ref_pkg.sv —— 单元级参考模型（只给 tb/unit 用，不参与综合）
//
//  ── 为什么参考模型要"另写一套算法"，而不是把 RTL 的写法照抄一遍 ────────
//  如果参考模型也写成「算术右移 + 余数比较」，那它和 RTL 就是同一段
//  逻辑的两次翻译：移位量算错、符号取反、次正规分支写反，两边会一起错，
//  对拍永远 PASS —— 这是单元验证里最常见的自欺。
//  所以这里统一走**实数（double）+ 显式 RNE 判定**这条路：
//
//      量化      : rne(x * 2^QF)              ← 数学定义，不关心硬件怎么移
//      exp2      : rne(t/2^16) → 查自己算的表 → 插值 → rne(/2^n)
//      定点→FP16 : 找 e 使 2^e <= |x| < 2^(e+1)，尾数 rne 后回填指数
//      倒数      : 照 fx.h 的 fx_rne_div() 逐行转写（它就是契约定义）
//
//  两条路径的"独立性"来源不同，写清楚免得被问：
//    · quant / fix2fp16 / exp2 的表：独立（实数定义 vs 整数移位结构）
//    · exp2 的常数 94548、LUT 分段规则：不独立（这是模型给的数值契约，
//      不是实现细节；它们错了，是模型错，由 make vec 那层负责）
//    · recip：算法独立（长除法 vs 整数除），判据定义相同（fx.h）
//
//  ── 精度说明 ────────────────────────────────────────────────────────
//  本文件所有中间量都是"整数 * 2 的整数次幂"，double 的 53 位尾数足以
//  精确表示，所以 rne() 的输入是精确值，不存在二次舍入。
//  唯一的例外是 exp2 的整数部分 t：d*94548/2^16 本来就要舍入，
//  这是契约要求的舍入点，正好由 rne() 承担。
// =====================================================================
`ifndef UNIT_REF_PKG_SV
`define UNIT_REF_PKG_SV

package unit_ref_pkg;
  import attn_pkg::*;

  localparam real LOG2E_Q16_R = 94548.0;   // 与 attn_pkg::LOG2E_Q16 同源

  // ---------------------------------------------------- 2^k（精确）
  // 不用 2.0**k：不同仿真器对 real 幂运算的精度处理不一致，
  // 连乘/连除的结果是确定的。
  function automatic real pow2i(input int k);
    real r = 1.0;
    if (k >= 0) for (int i = 0; i <  k; i++) r = r * 2.0;
    else        for (int i = 0; i < -k; i++) r = r / 2.0;
    return r;
  endfunction

  // ---------------------------------------------------- RNE：real → 整数
  // round-half-to-even，等价于 C 的 nearbyint()（默认舍入模式）。
  //   frac > 0.5 → 上；< 0.5 → 下；== 0.5 → 取偶数
  // 负数依赖 $floor 的向下取整（如 -2.5 → fl=-3, frac=0.5, -3 为奇 → -2）。
  function automatic longint rne(input real r);
    real    fl;
    real    fr;
    longint i;
    fl = $floor(r);
    fr = r - fl;
    i  = longint'(fl);
    if      (fr > 0.5) return i + 1;
    else if (fr < 0.5) return i;
    else               return ((i / 2) * 2 == i) ? i : i + 1;
  endfunction

  // ---------------------------------------------------- FP16 位模式 → 实数
  // 与 fp16.h 的 f16_to_d() 同义，但用连乘而不是 ldexp。
  // e==31（inf/nan）返回 65536.0 只作占位：调用方必须先排除这一档。
  function automatic real f16_to_r(input logic [15:0] h);
    int  e, m;
    real v;
    e = int'(h[14:10]);
    m = int'(h[9:0]);
    if      (e == 0)  v = m * pow2i(-24);              // 次正规：m * 2^-24
    else if (e == 31) v = 65536.0;                     // 占位，不参与比较
    else              v = (1024 + m) * pow2i(e - 25);   // (1+m/1024)*2^(e-15)
    return h[15] ? -v : v;
  endfunction

  // ---------------------------------------------------- 量化参考（fp16_quant）
  // 定义：iv = RNE(x * 2^QF)，再饱和到 QB 位有符号。
  function automatic longint quant_ref(input logic [15:0] h,
                                       input int qb, input int qf);
    longint iv, hi, lo;
    iv = rne(f16_to_r(h) * pow2i(qf));
    hi = (longint'(1) << (qb - 1)) - 1;
    lo = -(longint'(1) << (qb - 1));
    if (iv > hi) iv = hi;
    if (iv < lo) iv = lo;
    return iv;
  endfunction

  // ---------------------------------------------------- 实数 → FP16（fix2fp16）
  // 与 fp16.h 的 d_to_f16() 同义：正规/次正规/溢出三段，RNE。
  // 本工程输入是整数 y（值 y*2^-FRAC，非零时 >= 2^-13），永远走正规段；
  // 次正规段仍保留，用于验证 RTL 在未来参数下不会静默出错。
  function automatic logic [15:0] f16_from_r(input real xin);
    real    x, ax;
    logic   s;
    int     e, E, mant;
    longint q24;
    s = 1'b0;
    x = xin;
    if (x < 0.0) begin s = 1'b1; x = -x; end
    if (x == 0.0) return 16'h0000;
    ax = x;
    if (ax >= 65520.0) return {s, 5'h1F, 10'd0};        // 溢出 → inf

    if (ax < 6.103515625e-05) begin                      // 次正规：|x| < 2^-14
      q24 = rne(ax * 16777216.0);
      if (q24 >= 1024) return {s, 5'd1, 10'd0};
      return {s, 5'd0, q24[9:0]};
    end

    e = -14;
    while (pow2i(e + 1) <= ax) e = e + 1;                // 2^e <= ax < 2^(e+1)
    mant = int'(rne((ax / pow2i(e) - 1.0) * 1024.0));
    E = e + 15;
    if (mant == 1024) begin mant = 0; E = E + 1; end     // 尾数进位
    if (E >= 31) return {s, 5'h1F, 10'd0};
    return {s, E[4:0], mant[9:0]};
  endfunction

  // ------------------------------------------- 2^(-k/32) 表（自己算，不抄 RTL）
  // k = 0..32，Q16。RTL 侧那张 case 表若有一项写错，这里会指出来。
  function automatic int lut_val(input int k);
    if (k < 0 || k > 32) return 0;
    return int'(rne(65536.0 * $pow(2.0, -real'(k) / 32.0)));
  endfunction

  // ---------------------------------------------------- 2^(-d) 参考（exp2_unit）
  // 与 attn_model.c:exp2_neg() 同义，但用实数表达"乘 log2(e)、除 2^n"。
  function automatic logic [16:0] exp2_ref(input longint d_fx,
                                           input int lut_bits, input int s_frac);
    longint     t, rr;
    int         n, sb, idx, rem, stride;
    logic [15:0] f;
    real        a, b, e2;

    // t = RNE(d * log2(e))，F=s_frac → F=16
    t = rne(real'(d_fx) * LOG2E_Q16_R / pow2i(s_frac));
    if (t < 0) t = 0;                                    // 契约保证 d>=0，防御

    n = int'(t >>> 16);                                  // 整数部分
    f = 16'(t & 64'hFFFF);                               // 小数部分，F=16

    sb     = 16 - lut_bits;                              // 插值余量位宽
    stride = 5  - lut_bits;                              // 1/32 表抽取步长
    idx = int'(f >> sb);
    rem = int'(f) & ((1 << sb) - 1);

    a  = real'(lut_val(idx << stride));
    b  = real'(lut_val((idx + 1) << stride));
    // 线性插值：a + (b-a)*rem / 2^(16-b)，RNE
    e2 = a + real'(rne((b - a) * real'(rem) / pow2i(sb)));

    if (n >= EXP_ZERO_N) return 17'd0;                   // 2^-16 以下直接归零
    rr = rne(e2 / pow2i(n));                             // 乘 2^-n
    return rr[16:0];
  endfunction

  // ---------------------------------------------------- 倒数参考（recip_unit）
  // 照 fx.h:fx_rne_div() 逐行转写 —— 这段就是"逐位一致"的判据定义，
  // 所以不追求算法独立，只追求语义一致。
  function automatic longint recip_ref(input longint t);
    longint num, q, r;
    if (t <= 0) return 0;
    num = longint'(1) << RECIP_SH;
    q   = num / t;
    r   = num - q * t;
    if (2 * r > t || (2 * r == t && ((q / 2) * 2 != q))) q = q + 1;
    return q;
  endfunction

endpackage

`endif // UNIT_REF_PKG_SV
