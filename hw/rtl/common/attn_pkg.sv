// =====================================================================
//  attn_pkg.sv —— 三方案共用的类型与常数
//
//  铁律：任何方案都不许自己再定义一份类型或改这里的量化格式。
//        一旦格式不一致，三套结果就没法用同一张表对比，综合效率那 40 分直接作废。
//
//  ── 规模由题面锁死 ────────────────────────────────────────────────
//    题面：「Q、K、V、Y 均为 16×16 矩阵，Softmax 按行执行」。
//    所以 N = 16、每个矩阵 256 个元素，没有自由度。
//    早期版本这里写成 SEQ_LEN=8 / D_HEAD=64（照搬了通用 Transformer 的形状），
//    与 C 模型 ATTN_MX=16 对不上，会让「逐位一致」这项根本无从验证。
// =====================================================================
`ifndef ATTN_PKG_SV
`define ATTN_PKG_SV

package attn_pkg;

  // ---- 矩阵规模：题面固定 16×16 ----
  localparam int N     = 16;
  localparam int NELEM = N * N;          // 256，单个矩阵的元素数

  // ---- 外部数据格式：IEEE 754 binary16 ----
  typedef logic [15:0] fp16_t;

  // ---- 地址：单矩阵内 0..255，8 bit 恰好够 ----
  typedef logic [7:0]  addr_t;

  // ---- 装载通道的矩阵选择 ----
  typedef enum logic [1:0] {
    SEL_Q = 2'd0,
    SEL_K = 2'd1,
    SEL_V = 2'd2
  } ld_sel_t;

  // ---- 任务状态机（三个方案的顶层都按这套状态走，便于共用 tb）----
  typedef enum logic [2:0] {
    S_IDLE   = 3'd0,   // 等 start
    S_LOAD   = 3'd1,   // 装载 Q/K/V（tb 驱动，DUT 只需收下）
    S_QK     = 3'd2,   // S = Q·Kᵀ
    S_SOFTMX = 3'd3,   // P = softmax(S)
    S_PV     = 3'd4,   // O = P·V
    S_OUT    = 3'd5,   // 结果回读
    S_DONE   = 3'd6
  } state_t;

  // ---- 与 model/attn_model.h 逐字对应的数值契约 ----
  // 改动其中任何一个，都必须同步改模型并重跑 make vec，否则比对必然失配。
  localparam int S_FRAC     = 16;        // S 的定点小数位
  localparam int P_FRAC     = 16;        // p 的定点小数位
  localparam int Y_FRAC     = 13;        // 输出中间值小数位
  localparam int RECIP_SH     = 40;      // 倒数分子 2^40
  localparam int LOG2E_Q16  = 94548;     // round(log2(e) * 2^16)
  localparam int EXP_ZERO_N = 16;        // 2^-n，n >= 16 直接置 0
  localparam int EXP_LUT_BITS = 4;       // exp2 LUT 索引位（16 段 + 1 端点）

  // ---- FP16 常量 ----
  localparam fp16_t FP16_ZERO = 16'h0000;
  localparam fp16_t FP16_ONE  = 16'h3C00;
  localparam fp16_t FP16_INF  = 16'h7C00;
  localparam fp16_t FP16_NAN  = 16'h7E00;

  // ---- 有限值判定（题面要求输出必须是有限 FP16）----
  function automatic bit is_finite(fp16_t v);
    return (v[14:10] != 5'h1F);   // exp 全 1 即 inf/nan
  endfunction

endpackage

`endif // ATTN_PKG_SV
