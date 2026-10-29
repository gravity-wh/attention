/* =====================================================================
 *  fp16.h —— IEEE 754 binary16 编解码
 *
 *  为什么不用 _Float16：
 *    _Float16 的可用性依赖编译器与目标机，且舍入模式不可控；
 *    这里手工实现，保证「输入按 FP16 精确取值、输出按 RNE 舍入」在
 *    任何平台上逐位一致 —— 这是"与软件模型逐位一致"可复现的前提。
 * ===================================================================== */
#ifndef FP16_H
#define FP16_H

#include <math.h>
#include <stdint.h>

/* FP16 位模式 -> double（精确，无舍入） */
static inline double f16_to_d(uint16_t h)
{
    uint16_t s = (uint16_t)(h >> 15);
    uint16_t e = (uint16_t)((h >> 10) & 0x1F);
    uint16_t m = (uint16_t)(h & 0x3FF);
    double v;

    if (e == 0) {
        v = ldexp((double)m, -24);            /* 次正规：m * 2^-24 */
    } else if (e == 0x1F) {
        v = (m != 0) ? NAN : INFINITY;
    } else {
        v = ldexp((double)(m | 0x400), (int)e - 25);  /* (1+m/1024)*2^(e-15) */
    }
    return s ? -v : v;
}

/* double -> FP16 位模式（RNE，溢出到 inf，下溢到 0/次正规） */
static inline uint16_t d_to_f16(double x)
{
    uint16_t sign = 0;
    if (isnan(x)) return 0x7E00;
    if (x < 0.0 || (x == 0.0 && signbit(x))) { sign = 0x8000; x = -x; }
    if (x == 0.0) return sign;
    if (isinf(x) || x >= 65520.0) return (uint16_t)(sign | 0x7C00);

    /* 次正规区间：|x| < 2^-14，量化步长 2^-24 */
    if (x < 6.103515625e-05) {
        long q = (long)nearbyint(x * 16777216.0);   /* x * 2^24 */
        if (q >= 1024) return (uint16_t)(sign | 0x0400);  /* 进位到最小正规数 */
        return (uint16_t)(sign | (uint16_t)q);
    }

    int e;
    double m = frexp(x, &e);          /* x = m * 2^e, m ∈ [0.5, 1) */
    /* 正规数：x = (1.f) * 2^(e-15)，尾数 f = 2m - 1 */
    long mant = (long)nearbyint((2.0 * m - 1.0) * 1024.0);
    int E = e - 1 + 15;               /* 偏置指数 */
    if (mant == 1024) { mant = 0; E += 1; }   /* 尾数进位 */
    if (E >= 31) return (uint16_t)(sign | 0x7C00);
    return (uint16_t)(sign | (uint16_t)((E << 10) | (mant & 0x3FF)));
}

#endif /* FP16_H */
