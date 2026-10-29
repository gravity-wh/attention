// =====================================================================
//  attn_pkg.sv —— 三方案共用的类型与常数
//
//  铁律：任何方案都不许自己再定义一份 fp16 类型或改这里的量化格式。
//        一旦格式不一致，三套结果就没法用同一张表对比，综合效率那 40 分直接作废。
// =====================================================================
`ifndef ATTN_PKG_SV
`define ATTN_PKG_SV

package attn_pkg;

  // ---- 外部数据格式：IEEE 754 binary16 ----
  typedef logic [15:0] fp16_t;

  // ---- 内部累加格式：所有方案必须相同，否则「其余条件一致」不成立 ----
  // 先用 FP32 宽度做定点/浮点累加都行，但三个方案必须选定同一个并写在这里。
  typedef logic [31:0] acc_t;

  // ---- 地址宽度：够寻址 SEQ_LEN × D_HEAD 的元素 ----
  typedef logic [11:0] addr_t;

  // ---- 任务状态机（三个方案的顶层都按这套状态走，便于共用 tb）----
  typedef enum logic [2:0] {
    S_IDLE   = 3'd0,   // 等 start
    S_LOAD   = 3'd1,   // 装载 Q/K/V
    S_QK     = 3'd2,   // S = Q·Kᵀ
    S_SOFTMX = 3'd3,   // P = softmax(S)
    S_PV     = 3'd4,   // O = P·V
    S_OUT    = 3'd5,   // 结果回读
    S_DONE   = 3'd6
  } state_t;

  // ---- 矩阵规模（可按题目给的 shape 改；三方案必须一致）----
  localparam int SEQ_LEN = 8;
  localparam int D_HEAD  = 64;
  localparam int ELEMS   = SEQ_LEN * D_HEAD;

  // ---- FP16 常量 ----
  localparam fp16_t FP16_ZERO = 16'h0000;
  localparam fp16_t FP16_ONE  = 16'h3C00;
  localparam fp16_t FP16_INF  = 16'h7C00;
  localparam fp16_t FP16_NAN  = 16'h7E00;

  // ---- 有限值判定（题面要求输出必须是有限 FP16）----
  function automatic bit is_finite(fp16_t v);
    return (v[14:10] != 5'h1F);   // exp 全 1 即 inf/nan
  endfunction

  // ---- 16 位和 → 是否溢出（给累加与饱和用）----
  function automatic bit sat_needed(acc_t v);
    return (v > 32'sd65535) || (v < -32'sd32768);
  endfunction

endpackage

`endif // ATTN_PKG_SV
