/* =====================================================================
 *  fx.h —— 定点原语（bit-accurate 模型的算术底座）
 *
 *  设计原则：这里的每一个函数都必须能一对一映射成 RTL 里的硬件结构，
 *  不允许出现"只有软件能算"的操作（例如任何浮点中间量）。
 *
 *    fx_rne_shift  ->  桶形移位器 + {sum, sticky} 舍入逻辑
 *    fx_rne_div    ->  除法器/倒数 LUT（每次只做一次，见 softmax 的 R）
 *
 *  舍入统一用 round-half-to-even（RNE）：
 *    - 无累积偏置，误差不随层数漂；对称处理正负数；
 *    - 对应 Verilog 里 `sum[sh-1:0]` 的舍入判断，可在 2 级逻辑内实现。
 * ===================================================================== */
#ifndef FX_H
#define FX_H

#include <stdint.h>

/* 算术右移 + RNE 舍入。
 *   sh > 0  ：右移 sh 位并舍入（x 可为负）
 *   sh < 0  ：左移 -sh 位，无舍入
 * 前提：|sh| < 62，且左移不会溢出（本工程由调用点保证）。
 * 注意：依赖算术右移对负数向下取整，GCC/Clang/Verilog >>> 均为该语义。 */
static inline int64_t fx_rne_shift(int64_t x, int sh)
{
    if (sh == 0) return x;
    if (sh < 0)  return x << (-sh);

    int64_t q = x >> sh;              /* 向下取整（负数往 -inf） */
    int64_t r = x - (q << sh);        /* 0 <= r < 2^sh */
    int64_t h = (int64_t)1 << (sh - 1);
    if (r > h || (r == h && (q & 1)))
        q += 1;
    return q;
}

/* 带 RNE 的整数除法，要求 den > 0。
 * 仅用于 softmax 里每行一次 r = 2^40 / T，对应 RTL 的一个倒数单元。 */
static inline int64_t fx_rne_div(int64_t num, int64_t den)
{
    int64_t q = num / den;
    int64_t r = num % den;
    int64_t a = (r < 0) ? -r : r;
    int64_t two_a = 2 * a;
    if (two_a > den || (two_a == den && (q & 1)))
        q += (num < 0) ? -1 : 1;
    return q;
}

/* 有符号饱和，RTL 用简单的比较-选择即可 */
static inline int32_t fx_sat(int64_t v, int bits)
{
    int64_t hi = ((int64_t)1 << (bits - 1)) - 1;
    int64_t lo = -((int64_t)1 << (bits - 1));
    if (v > hi) return (int32_t)hi;
    if (v < lo) return (int32_t)lo;
    return (int32_t)v;
}

#endif /* FX_H */
