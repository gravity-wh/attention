// =====================================================================
//  attn_math.svh —— 定点算术原语（core 三个模块共用）
//
//  这里的每个函数都必须在 model/ 的 C 代码里有逐位对应物，
//  否则「与软件模型逐位一致」这一项就无从谈起：
//      attn_rne_shift  <->  fx.h : fx_rne_shift()
//      attn_sat        <->  fx.h : fx_sat()
//      attn_exp2_lut   <->  attn_model.c : EXP2_LUT32[33]
//
//  为什么写成 .svh 里的 function 而不是 package：
//    这几个原语要在 always_comb 里当表达式用，VCS 与 Genus 对
//    package 内 function 的自动/静态判定有过不一致的历史；
//    include 到各自模块里，每个模块拿到一份私有副本，最省心。
//    代价是编译期多一点重复解析，可忽略。
// =====================================================================
`ifndef ATTN_MATH_SVH
`define ATTN_MATH_SVH

// ---------------------------------------------------------------- RNE 右移
// 算术右移 sh 位，按 round-half-to-even 舍入。
//   sh > 0 : 右移 + 舍入（x 可负，负数向下取整后再判余数）
//   sh == 0: 原样返回
//   sh < 0 : 左移 -sh 位（无舍入）—— 只为参数化时 QF 较小的情况兜底
//
// 对应 fx_rne_shift()：q = x >> sh（向下取整），r = x - (q<<sh)，
// r > half 或 (r == half && q 为奇数) 时 q+1。
// 硬件：算术右移 + 一个比较器，2 级逻辑。
function automatic logic signed [63:0] attn_rne_shift(input logic signed [63:0] x,
                                                     input int                sh);
  logic signed [63:0] q;
  logic        [63:0] r;
  logic        [63:0] h;
  if (sh == 0) return x;
  if (sh <  0) return x <<< (-sh);
  q = x >>> sh;
  r = x - (q <<< sh);          // 0 <= r < 2^sh（算术右移的性质）
  h = 64'd1 << (sh - 1);
  if (r > h || (r == h && q[0])) q = q + 64'sd1;
  return q;
endfunction

// ---------------------------------------------------------------- 有符号饱和
// 对应 fx_sat()。W 是本工程里手写常量的位宽上界，综合时全常数折叠。
function automatic logic signed [63:0] attn_sat(input logic signed [63:0] v,
                                                input int                w);
  logic signed [63:0] hi;
  logic signed [63:0] lo;
  hi = (64'sd1 <<< (w - 1)) - 64'sd1;
  lo = -(64'sd1 <<< (w - 1));
  if (v > hi) return hi;
  if (v < lo) return lo;
  return v;
endfunction

// ------------------------------------------------------- 2^(-k/32) 表，Q16
// 与 attn_model.c 的 EXP2_LUT32[33] 逐项相同（k = 0..32）。
//
// 为什么用 case 而不是 localparam 数组 '{...}：
//   `'{...}` 赋值模式在 DC/Genus 上的支持一直不稳，而 case 就是一张
//   17 位宽的查找表，综合出来完全一样，且任何工具都吃得下。
// 注意表值最大 65536，必须 17 位存放（用 16 位会把 k=0 截成 0，
// 导致 d=0 处的 exp 变 0，整行 softmax 崩掉——C 侧踩过同一个坑）。
function automatic logic [16:0] attn_exp2_lut(input int idx);
  case (idx)
     0: attn_exp2_lut = 17'd65536;
     1: attn_exp2_lut = 17'd64132;
     2: attn_exp2_lut = 17'd62757;
     3: attn_exp2_lut = 17'd61413;
     4: attn_exp2_lut = 17'd60097;
     5: attn_exp2_lut = 17'd58809;
     6: attn_exp2_lut = 17'd57549;
     7: attn_exp2_lut = 17'd56316;
     8: attn_exp2_lut = 17'd55109;
     9: attn_exp2_lut = 17'd53928;
    10: attn_exp2_lut = 17'd52773;
    11: attn_exp2_lut = 17'd51642;
    12: attn_exp2_lut = 17'd50535;
    13: attn_exp2_lut = 17'd49452;
    14: attn_exp2_lut = 17'd48393;
    15: attn_exp2_lut = 17'd47356;
    16: attn_exp2_lut = 17'd46341;
    17: attn_exp2_lut = 17'd45348;
    18: attn_exp2_lut = 17'd44376;
    19: attn_exp2_lut = 17'd43425;
    20: attn_exp2_lut = 17'd42495;
    21: attn_exp2_lut = 17'd41584;
    22: attn_exp2_lut = 17'd40693;
    23: attn_exp2_lut = 17'd39821;
    24: attn_exp2_lut = 17'd38968;
    25: attn_exp2_lut = 17'd38133;
    26: attn_exp2_lut = 17'd37316;
    27: attn_exp2_lut = 17'd36516;
    28: attn_exp2_lut = 17'd35734;
    29: attn_exp2_lut = 17'd34968;
    30: attn_exp2_lut = 17'd34219;
    31: attn_exp2_lut = 17'd33486;
    32: attn_exp2_lut = 17'd32768;
    default: attn_exp2_lut = 17'd0;
  endcase
endfunction

`endif // ATTN_MATH_SVH
