/* =====================================================================
 *  attn_model.c —— bit-accurate 定点模型
 *
 *  逐行对应将来的 RTL：
 *    量化      -> quant_to_fx()      对应输入寄存 + 舍入
 *    点积      -> 三处 acc 循环       对应 MAC 阵列 + int64 累加器
 *    exp2      -> exp2_neg()         对应 bucket + LUT + 插值 + 移位
 *    归一化    -> 一次 R + 16 次乘     对应 1 个倒数单元 + 16 个乘法器
 * ===================================================================== */
#include "attn_model.h"
#include "fx.h"
#include "fp16.h"

#include <math.h>

/* 注意：表值最大 65536（k=0，即 2^0 的 Q16 表示），
 * 必须用 int32_t 存放；用 uint16_t 会把 65536 截断成 0，
 * 导致 d=0 处的 exp 值为 0、整行 softmax 崩掉。这是实测踩过的坑。 */
const int32_t EXP2_LUT32[33] = {
    65536, 64132, 62757, 61413, 60097, 58809, 57549, 56316,
    55109, 53928, 52773, 51642, 50535, 49452, 48393, 47356,
    46341, 45348, 44376, 43425, 42495, 41584, 40693, 39821,
    38968, 38133, 37316, 36516, 35734, 34968, 34219, 33486,
    32768
};

void attn_reset(void)
{
    /* 本模型为纯组合函数，无跨任务状态。
     * RTL 的复位要清：S/P 缓冲、行 max 寄存器、累加器、控制状态机。
     * 「复位及恢复」用例验证的正是这些状态不会跨任务泄漏。 */
}

/* ---------------------------------------------------------------- 量化 */
static int32_t quant_to_fx(double x, const attn_cfg_t *c)
{
    double  s  = ldexp(1.0, c->qf);
    int64_t iv = (int64_t)nearbyint(x * s);   /* RNE */
    int64_t hi = ((int64_t)1 << (c->qb - 1)) - 1;
    int64_t lo = -((int64_t)1 << (c->qb - 1));
    if (iv > hi) iv = hi;                     /* 正常数据永不触发，留作防御 */
    if (iv < lo) iv = lo;
    return (int32_t)iv;
}

/* ------------------------------------------------- 2^(-d)，d >= 0，F=S_FRAC
 * 返回 F=16 的定点值，范围 [0, 65536]。
 *
 * 数学：2^(-d) = 2^(-n) * 2^(-f)，其中 d*log2(e) = n + f，
 *       n 为整数部分（移位，免费），f ∈ [0,1) 交给 LUT。
 * 硬件：一个乘法（LOG2E_Q16）+ 一个桶形移位 + 一个 LUT + 一个插值乘法。 */
static int32_t exp2_neg(int32_t d_fx, const attn_cfg_t *c)
{
    /* t = d * log2(e)，从 F=S_FRAC 转到 F=16 */
    int64_t t = fx_rne_shift((int64_t)d_fx * LOG2E_Q16, S_FRAC);

    int64_t  n = t >> 16;                        /* 整数部分，>= 0 */
    uint32_t f = (uint32_t)(t & 0xFFFF);         /* 小数部分，F=16 */

    if (n >= EXP_ZERO_N) return 0;               /* 2^-16 = 1.5e-5，已可忽略 */

    int b      = c->lut_bits;
    int stride = 5 - b;                          /* 从 1/32 表抽取 1/2^b 粒度 */
    int idx    = (int)(f >> (16 - b));
    int rem    = (int)(f & ((1u << (16 - b)) - 1));   /* 插值余量 */

    int32_t a  = (int32_t)EXP2_LUT32[idx << stride];
    int32_t bb = (int32_t)EXP2_LUT32[(idx + 1) << stride];

    /* 线性插值：a + (bb-a)*rem/2^(16-b)，RNE */
    int64_t e2 = a + fx_rne_shift((int64_t)(bb - a) * rem, 16 - b);

    return (int32_t)fx_rne_shift(e2, (int)n);    /* 乘 2^-n */
}

/* ------------------------------------------------------------- 主流程 */
void attn_fixed(const attn_cfg_t *c, const mat_in_t *in, mat_out_t *out)
{
    int32_t qf[ATTN_MX][ATTN_MX];
    int32_t kf[ATTN_MX][ATTN_MX];
    int32_t vf[ATTN_MX][ATTN_MX];
    int32_t S[ATTN_MX][ATTN_MX];
    int32_t P[ATTN_MX][ATTN_MX];
    int i, j, k;

    /* ---- 1. 量化：FP16 -> s(QB).QF ---- */
    for (i = 0; i < ATTN_MX; i++) {
        for (j = 0; j < ATTN_MX; j++) {
            qf[i][j] = quant_to_fx(in->q[i][j], c);
            kf[i][j] = quant_to_fx(in->k[i][j], c);
            vf[i][j] = quant_to_fx(in->v[i][j], c);
        }
    }

    /* ---- 2. S = Q·Kᵀ / 4 ----
     * 真实值 = acc * 2^(-2*QF) / 4 = acc * 2^(-2*QF-2)
     * 目标   = S_fx * 2^(-S_FRAC)
     * => shift = (2*QF + 2) - S_FRAC（可能为负，即左移） */
    {
        int sh = 2 * c->qf + 2 - S_FRAC;
        for (i = 0; i < ATTN_MX; i++) {
            for (j = 0; j < ATTN_MX; j++) {
                int64_t acc = 0;
                for (k = 0; k < ATTN_MX; k++)
                    acc += (int64_t)qf[i][k] * (int64_t)kf[j][k];
                S[i][j] = (int32_t)fx_rne_shift(acc, sh);
            }
        }
    }

    /* ---- 3. 逐行 Softmax ---- */
    for (i = 0; i < ATTN_MX; i++) {
        int32_t m = S[i][0];
        for (j = 1; j < ATTN_MX; j++)
            if (S[i][j] > m) m = S[i][j];

        int64_t e[ATTN_MX];
        int64_t T = 0;

        if (c->approx) {
            /* ---- 3a. RTL 契约路径：LUT exp2 + 一次倒数 ---- */
            for (j = 0; j < ATTN_MX; j++) {
                int32_t d = m - S[i][j];                 /* >= 0, F=S_FRAC */
                e[j] = (int64_t)exp2_neg(d, c);          /* F=16 */
                T   += e[j];
            }
            /* R ≈ 2^40 / T，每行一次；对应 RTL 一个倒数单元 */
            int64_t R = fx_rne_div((int64_t)1 << RECIP_SHIFT, T);
            for (j = 0; j < ATTN_MX; j++) {
                /* e*2^40/T >> (40-16) = e*2^16/T = p 的 F=16 表示 */
                P[i][j] = (int32_t)fx_rne_shift(e[j] * R, RECIP_SHIFT - 16);
                if (P[i][j] < 0)          P[i][j] = 0;
                if (P[i][j] > (1 << 16))  P[i][j] = (1 << 16);
            }
        } else {
            /* ---- 3b. 误差分解用的「无近似」路径 ----
             * 仍量化到 F=16，但不引入 LUT 与倒数，用来单独衡量
             * 「定点格式本身」贡献了多少误差。 */
            double ev[ATTN_MX];
            for (j = 0; j < ATTN_MX; j++) {
                double d = (double)(m - S[i][j]) / ldexp(1.0, S_FRAC);
                double x = exp(-d) * 65536.0;
                int64_t q = (int64_t)nearbyint(x);
                if (q > 65536) q = 65536;
                ev[j] = (double)q;
                e[j]  = q;
                T    += q;
            }
            (void)ev;
            for (j = 0; j < ATTN_MX; j++) {
                int64_t p = fx_rne_div(e[j] * 65536, T);
                if (p < 0)          p = 0;
                if (p > (1 << 16))  p = (1 << 16);
                P[i][j] = (int32_t)p;
            }
        }

        /* 行和自检：理想值 65536（即 p 的和为 1.0） */
        {
            int32_t s = 0;
            for (j = 0; j < ATTN_MX; j++) s += P[i][j];
            out->psum[i] = s;
        }
    }

    /* ---- 4. Y = P·V ----
     * 真实值 = acc * 2^(-P_FRAC) * 2^(-QF)，目标 F=Y_FRAC
     * => shift = P_FRAC + QF - Y_FRAC */
    {
        int sh = P_FRAC + c->qf - Y_FRAC;
        for (i = 0; i < ATTN_MX; i++) {
            for (j = 0; j < ATTN_MX; j++) {
                int64_t acc = 0;
                for (k = 0; k < ATTN_MX; k++)
                    acc += (int64_t)P[i][k] * (int64_t)vf[k][j];
                int32_t y = (int32_t)fx_rne_shift(acc, sh);
                out->y[i][j] = d_to_f16(ldexp((double)y, -Y_FRAC));
            }
        }
    }
}

/* --------------------------------------------------------- float64 参考 */
void attn_ref(const mat_in_t *in, double y[ATTN_MX][ATTN_MX])
{
    double S[ATTN_MX][ATTN_MX];
    double P[ATTN_MX][ATTN_MX];
    int i, j, k;

    for (i = 0; i < ATTN_MX; i++) {
        for (j = 0; j < ATTN_MX; j++) {
            double acc = 0.0;
            for (k = 0; k < ATTN_MX; k++)
                acc += in->q[i][k] * in->k[j][k];
            S[i][j] = acc / 4.0;
        }
    }

    for (i = 0; i < ATTN_MX; i++) {
        double m = S[i][0], sum = 0.0;
        for (j = 1; j < ATTN_MX; j++)
            if (S[i][j] > m) m = S[i][j];
        for (j = 0; j < ATTN_MX; j++) {
            P[i][j] = exp(S[i][j] - m);
            sum += P[i][j];
        }
        for (j = 0; j < ATTN_MX; j++) P[i][j] /= sum;
    }

    for (i = 0; i < ATTN_MX; i++) {
        for (j = 0; j < ATTN_MX; j++) {
            double acc = 0.0;
            for (k = 0; k < ATTN_MX; k++)
                acc += P[i][k] * in->v[k][j];
            y[i][j] = acc;
        }
    }
}
