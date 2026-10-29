/* =====================================================================
 *  vecgen.c —— 六类测试向量
 *
 *  铁律：所有输入先经 FP16 往返量化（f16_to_d(d_to_f16(x))），
 *        这样"输入"与题面「相同 FP16 输入」严格一致，
 *        float64 参考算的就是这些 FP16 精确值，不存在口径差。
 * ===================================================================== */
#include "vecgen.h"
#include "fp16.h"

#include <math.h>

static uint64_t g_state;

static uint64_t rng_next(void)
{
    /* xorshift64*：够快、够用、跨平台确定 */
    uint64_t x = g_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    g_state = x;
    return x * 2685821657736338717ULL;
}

static double u01(void)                       /* [0,1) */
{
    return (double)(rng_next() >> 11) * (1.0 / 9007199254740992.0);
}

static double urange(double lo, double hi)    /* [lo,hi) */
{
    return lo + (hi - lo) * u01();
}

static int rint_below(int n)                  /* [0,n) */
{
    return (int)(rng_next() % (uint64_t)n);
}

/* FP16 往返量化：断言输入是 FP16 可精确表示的值 */
static double as_fp16(double x)
{
    return f16_to_d(d_to_f16(x));
}

const char *cat_name(cat_t c)
{
    switch (c) {
    case CAT_RANDOM:  return "random";
    case CAT_ZERO:    return "all-zero";
    case CAT_EXTREME: return "extreme";
    case CAT_CANCEL:  return "cancellation";
    case CAT_RESET:   return "reset-recover";
    case CAT_CONT:    return "consecutive";
    default:          return "?";
    }
}

void vec_seed(uint64_t seed)
{
    g_state = seed ? seed : 0x9E3779B97F4A7C15ULL;
    /* 预热，避免小 seed 的线性相关 */
    for (int i = 0; i < 16; i++) (void)rng_next();
}

int cat_runs(cat_t c)
{
    switch (c) {
    case CAT_RANDOM:  return 200;
    case CAT_EXTREME: return 200;
    case CAT_CANCEL:  return 200;
    case CAT_ZERO:    return 4;
    case CAT_RESET:   return 4;    /* 4 个任务 × 复位后重跑 */
    case CAT_CONT:    return 8;    /* 8 个连续任务 */
    default:          return 1;
    }
}

/* ---------------------------------------------------- 各类别生成器 ---- */

static void gen_random(mat_in_t *m, int idx)
{
    (void)idx;
    for (int i = 0; i < ATTN_MX; i++)
        for (int j = 0; j < ATTN_MX; j++) {
            m->q[i][j] = as_fp16(urange(-2.0, 2.0));
            m->k[i][j] = as_fp16(urange(-2.0, 2.0));
            m->v[i][j] = as_fp16(urange(-2.0, 2.0));
        }
}

static void gen_zero(mat_in_t *m, int idx)
{
    (void)idx;
    for (int i = 0; i < ATTN_MX; i++)
        for (int j = 0; j < ATTN_MX; j++) {
            m->q[i][j] = 0.0;
            m->k[i][j] = 0.0;
            m->v[i][j] = 0.0;
        }
    /* 变体：只让 V 非零，检验 0/0 不会产生 NaN */
    if (idx % 2) {
        for (int i = 0; i < ATTN_MX; i++)
            for (int j = 0; j < ATTN_MX; j++)
                m->v[i][j] = as_fp16(urange(-2.0, 2.0));
    }
}

/* 极值：取值集合 {-2,-1,0,1,2}，并强制出现全 +2 行与全 -2 行 */
static void gen_extreme(mat_in_t *m, int idx)
{
    static const double lv[5] = { -2.0, -1.0, 0.0, 1.0, 2.0 };
    (void)idx;

    for (int i = 0; i < ATTN_MX; i++)
        for (int j = 0; j < ATTN_MX; j++) {
            m->q[i][j] = lv[rint_below(5)];
            m->k[i][j] = lv[rint_below(5)];
            m->v[i][j] = lv[rint_below(5)];
        }
    /* 第 0 行/列全 +2，第 1 行/列全 -2：直接打饱和与符号对称 */
    for (int j = 0; j < ATTN_MX; j++) {
        m->q[0][j] =  2.0;  m->k[0][j] =  2.0;  m->v[0][j] =  2.0;
        m->q[1][j] = -2.0;  m->k[1][j] = -2.0;  m->v[1][j] = -2.0;
    }
}

/* 相消：两类子形态交替，覆盖两种不同的失效机理。
 *
 *  (a) 偶数 idx —— Hadamard 正交符号pattern
 *      H[i][k] = (-1)^popcount(i & k)，行与行正交。
 *      效果：i≠j 时 16 个正负项对消到近零，i==j 时同号累加到满量程。
 *      考的是**累加器**：中间和达到 ±32（S 单位），终值却接近 0。
 *
 *  (b) 奇数 idx —— 近并行 K 行 + 交替符号
 *      K 的 16 行都近似平行于同一个 ±1 向量 u，只是幅度不同。
 *      于是同一行内 16 个 S 值彼此接近，softmax 接近均匀分布——
 *      这是对 δS 最敏感的工况：δS 再小也会等比例挪动 p。
 *      考的是 **softmax 的数值分辨率**。
 *
 * 只做 (a) 是不够的：Hadamard 会让每行出现一个 16 的绝对主峰，
 * softmax 退化成 one-hot，误差反而比随机数据更小（实测如此）。
 * 必须补 (b) 才能压住"相消 + 近均匀 softmax"这个真正的难点。 */
static int hadamard_sign(int i, int k)
{
    unsigned v = (unsigned)(i & k);
    int par = 0;
    for (int t = 0; t < 5; t++) par ^= (int)((v >> t) & 1u);
    return par ? -1 : 1;
}

static void gen_cancel(mat_in_t *m, int idx)
{
    if (idx % 2) {
        /* (b) 近并行 K 行 */
        int u[ATTN_MX];
        for (int k = 0; k < ATTN_MX; k++) u[k] = (rng_next() & 1) ? 1 : -1;

        for (int i = 0; i < ATTN_MX; i++)
            for (int k = 0; k < ATTN_MX; k++)
                m->q[i][k] = as_fp16(u[k] * urange(1.6, 2.0));
        /* K 行 = 同一个 u 乘不同幅度，符号再交替，制造行间差异 */
        for (int j = 0; j < ATTN_MX; j++) {
            double amp = ((j & 1) ? -1.0 : 1.0) * urange(1.6, 2.0);
            for (int k = 0; k < ATTN_MX; k++)
                m->k[j][k] = as_fp16(u[k] * amp);
        }
    } else {
        /* (a) Hadamard 正交 */
        for (int i = 0; i < ATTN_MX; i++)
            for (int k = 0; k < ATTN_MX; k++) {
                /* 幅度在 [1.7,2.0] 内随机，破坏"精确正交"，让残差非零 */
                m->q[i][k] = as_fp16(hadamard_sign(i, k) * urange(1.7, 2.0));
                m->k[i][k] = as_fp16(hadamard_sign(i, k) * urange(1.7, 2.0));
            }
    }
    for (int i = 0; i < ATTN_MX; i++)
        for (int j = 0; j < ATTN_MX; j++)
            m->v[i][j] = as_fp16(urange(-2.0, 2.0));
}

void vec_make(cat_t c, int idx, mat_in_t *out)
{
    switch (c) {
    case CAT_RANDOM:  gen_random(out, idx);  break;
    case CAT_ZERO:    gen_zero(out, idx);    break;
    case CAT_EXTREME: gen_extreme(out, idx); break;
    case CAT_CANCEL:  gen_cancel(out, idx);  break;
    case CAT_RESET:   gen_random(out, idx);  break;  /* 复位用例用普通随机任务 */
    case CAT_CONT:    gen_random(out, idx);  break;  /* 连续任务同理 */
    default:          gen_random(out, idx);  break;
    }
}
