/* =====================================================================
 *  attn_model.h —— 定点自注意力的「数值契约」
 *
 *  这个头文件就是 RTL 的规格书。RTL 只有在下面每条都逐位对上时，
 *  才能通过"与自身软件模型逐位一致"这一项。
 *
 *  ── 数据流与定点格式总表 ───────────────────────────────────────────
 *   阶段                格式            小数位   说明
 *   ------------------  --------------  -------  ---------------------
 *   输入 Q/K/V          FP16            —        |x| <= 2，题面限定
 *   量化后 q/k/v        s(QB).QF         QF       存 s16/s8，范围 ±4
 *   QKᵀ 累加            int64 精确      —        16 项，无截断
 *   S = QKᵀ/4           s32.16          16       进 softmax 前的唯一格式
 *   d = m - S           s32.16          16       >= 0
 *   t = d*log2(e)       s32.16          16       转成以 2 为底
 *   2^(-t)  = e_i       s32.16          16       [0,1]，LUT+线性插值
 *   行和 T              int32           —        [2^16, 16·2^16]
 *   倒数 R = 2^40/T     int64           —        每行一次
 *   p_i = e_i*R>>24     s32.16          16       [0,1]，Σp ≈ 1
 *   PV 累加             int64 精确      —        16 项
 *   y = P·V             s32.13          13       |y| <= 2
 *   输出                FP16            —        RNE
 *
 *  ── 三个自主决策（报告里要论证的）─────────────────────────────────
 *  1) Q/K/V 用 QF = QB - 3，即留 1 bit 幅度余量让表示范围到 ±4 而不是 ±2。
 *     代价是有效位数少约 1.3 bit；收益是**永不饱和**——题面的"正负极值"
 *     测试专打饱和，这一 bit 换来该类用例零风险。
 *  2) Softmax 走 2 的幂分解 + LUT 分段线性，而不是查 exp 大表：
 *     指数部分 free（移位），小数部分只需 LUT_BITS 位索引，误差可控到 1e-4 量级。
 *  3) 归一化用「每行一次倒数 + 16 次乘法」，而不是 16 次除法：
 *     RTL 上把除法器从 16 个降到 1 个，面积换精度的典型取舍。
 * ===================================================================== */
#ifndef ATTN_MODEL_H
#define ATTN_MODEL_H

#include <stdint.h>

#define ATTN_MX 16                     /* 矩阵阶数 */

/* ---- 数值契约常量：改这里等于改 RTL ---- */
#define S_FRAC        16               /* S 的定点小数位 */
#define P_FRAC        16               /* p 的定点小数位 */
#define Y_FRAC        13               /* 输出中间值的定点小数位 */
#define RECIP_SHIFT   40               /* 倒数分子 = 2^RECIP_SHIFT */
#define LOG2E_Q16     94548            /* round(log2(e) * 2^16) */
#define EXP_ZERO_N    16               /* 2^-n 当 n >= 16 时直接置 0 */

typedef struct {
    int qb;        /* Q/K/V 存储位宽（有符号）：16 / 12 / 10 / 8 */
    int qf;        /* Q/K/V 小数位：qb - 3，范围 ±4 */
    int lut_bits;  /* exp2 LUT 索引位：2..5（4 -> 16 项 + 1 端点） */
    int approx;    /* 1 = LUT + 倒数（RTL 契约）；0 = 精确 exp/除（做误差分解用）*/
} attn_cfg_t;

typedef struct {
    double q[ATTN_MX][ATTN_MX];   /* 已是 FP16 精确值的 double 表示 */
    double k[ATTN_MX][ATTN_MX];
    double v[ATTN_MX][ATTN_MX];
} mat_in_t;

typedef struct {
    uint16_t y[ATTN_MX][ATTN_MX]; /* FP16 位模式 */
    int32_t  psum[ATTN_MX];       /* 每行 Σp（F=16，理想值 65536），自检用 */
} mat_out_t;

/* round(2^(-k/32) * 2^16)，k = 0..32。
 * 统一以 1/32 粒度存放最大分辨率的表，小 lut_bits 按 stride 抽取，
 * 保证不同 LUT_BITS 下取到的都是准确的 2^(-k/2^b)。 */
extern const int32_t EXP2_LUT32[33];

/* 复位：本模型无跨任务状态，保留此接口是为了在 RTL 到位后
 * 「复位及恢复」「连续任务」两类用例可以直接复用同一套驱动代码。 */
void attn_reset(void);

void attn_fixed(const attn_cfg_t *cfg, const mat_in_t *in, mat_out_t *out);

/* float64 参考（评分用）：输入取 FP16 精确值，全程 double。
 * 输出必须跨机器逐位可复现 —— 内部 exp 用 attn_exp_f64()，不调 libm。 */
void attn_ref(const mat_in_t *in, double y[ATTN_MX][ATTN_MX]);

/* 确定性 exp(x)：只用 IEEE-754 基本四则 + ldexp，不依赖任何 libm 实现。
 * 与 glibc 的 exp() 最大偏差 1 ulp；同样输入在任何平台都得到同一串位。
 * 用途：让 ref.hex 在 Windows / Linux / 不同 gcc 之间字节一致。 */
double attn_exp_f64(double x);

#endif /* ATTN_MODEL_H */
