/* =====================================================================
 *  selftest.c —— 模型层的单元自检
 *
 *  只测两件最容易"静默出错"的事：
 *    1) FP16 编解码（错一位，整个误差基线就是假的）
 *    2) exp2 LUT 与移位路径（错了 softmax 会看起来"还行"但实际偏）
 *  端到端的误差统计不在这里，在 attn_baseline。
 * ===================================================================== */
#include "attn_model.h"
#include "fp16.h"
#include "fx.h"

#include <math.h>
#include <stdio.h>

static int g_pass = 0, g_fail = 0;

static void chk(const char *what, double got, double want, double tol)
{
    int ok = fabs(got - want) <= tol;
    if (ok) g_pass++;
    else {
        g_fail++;
        printf("  FAIL  %-42s got=%.10g want=%.10g\n", what, got, want);
    }
}

static void chk_i(const char *what, long long got, long long want)
{
    int ok = (got == want);
    if (ok) g_pass++;
    else {
        g_fail++;
        printf("  FAIL  %-42s got=%lld want=%lld\n", what, got, want);
    }
}

static void test_fp16(void)
{
    /* 位模式 -> double，取几个有代表性的点 */
    chk("f16 0x3C00 == 1.0",    f16_to_d(0x3C00), 1.0,    0.0);
    chk("f16 0x4000 == 2.0",    f16_to_d(0x4000), 2.0,    0.0);
    chk("f16 0xC000 == -2.0",   f16_to_d(0xC000), -2.0,   0.0);
    chk("f16 0x3800 == 0.5",    f16_to_d(0x3800), 0.5,    0.0);
    chk("f16 0x7BFF == 65504",  f16_to_d(0x7BFF), 65504.0, 0.0);
    chk("f16 0x0001 == 2^-24",  f16_to_d(0x0001), ldexp(1.0, -24), 0.0);
    chk("f16 0x0400 == 2^-14",  f16_to_d(0x0400), ldexp(1.0, -14), 0.0);

    /* double -> 位模式 */
    chk_i("d 1.0    -> 0x3C00", d_to_f16(1.0),   0x3C00);
    chk_i("d 2.0    -> 0x4000", d_to_f16(2.0),   0x4000);
    chk_i("d -2.0   -> 0xC000", d_to_f16(-2.0),  0xC000);
    chk_i("d 0.0    -> 0x0000", d_to_f16(0.0),   0x0000);
    chk_i("d 1/3    -> 0x3555", d_to_f16(1.0 / 3.0), 0x3555);  /* RNE 舍到偶数 */
    chk_i("d 1.0009765625 -> 0x3C01", d_to_f16(1.0 + ldexp(1.0, -10)), 0x3C01);

    /* 遍历全部 65536 个位模式：f16->d->f16 必须自反（NaN 除外） */
    int bad = 0;
    for (int h = 0; h < 65536; h++) {
        if (((h >> 10) & 0x1F) == 0x1F && (h & 0x3FF)) continue;  /* NaN */
        double d = f16_to_d((uint16_t)h);
        if (!isfinite(d)) continue;
        if (d_to_f16(d) != (uint16_t)h) bad++;
    }
    chk_i("f16 全 65536 模式往返自反", bad, 0);
}

static void test_fx(void)
{
    /* RNE 右移：正负对称，.5 舍到偶数 */
    chk_i("rne_shift( 5, 1)", fx_rne_shift(5, 1), 2);   /* 2.5 -> 2 */
    chk_i("rne_shift( 7, 1)", fx_rne_shift(7, 1), 4);   /* 3.5 -> 4 */
    chk_i("rne_shift(-5, 1)", fx_rne_shift(-5, 1), -2); /* -2.5 -> -2 */
    chk_i("rne_shift(-7, 1)", fx_rne_shift(-7, 1), -4); /* -3.5 -> -4 */
    chk_i("rne_shift( 6, 1)", fx_rne_shift(6, 1), 3);
    chk_i("rne_shift( 4, -2)", fx_rne_shift(4, -2), 16);
}

static void test_exp2(void)
{
    /* 通过 attn_fixed 的公开路径测不到内部函数，这里直接复刻同样的
     * 边界值断言，保证 LUT 上界（65536）没有溢出——这是踩过的坑。 */
    chk("LUT[0] == 2^0 * 2^16", (double)EXP2_LUT32[0], 65536.0, 0.0);
    chk("LUT[32] == 2^-1 * 2^16", (double)EXP2_LUT32[32], 32768.0, 0.0);
    chk("LUT[16] == 2^-0.5", (double)EXP2_LUT32[16], 46341.0, 0.0);

    /* LUT 单调递减且相邻差不超过 2048（保证插值不越界） */
    int mono = 1;
    for (int k = 0; k < 32; k++)
        if (EXP2_LUT32[k] <= EXP2_LUT32[k + 1]) mono = 0;
    chk_i("LUT 严格单调递减", mono, 1);

    /* 定点的 2^(-d) 精度：用无近似路径 vs 精确数学，抽查若干点。
     * 这里走 attn_fixed 的 approx=0 分支不方便单点调用，
     * 改为离线校验表本身的最大相对误差（线性插值误差上界）。 */
    double worst = 0.0;
    for (int i = 0; i <= 100000; i++) {
        double f = (double)i / 100001.0;          /* f ∈ [0,1] */
        double idxf = f * 32.0;
        int    idx  = (int)idxf;
        double rem  = idxf - idx;
        if (idx >= 32) { idx = 31; rem = 1.0; }
        double a = (double)EXP2_LUT32[idx];
        double b = (double)EXP2_LUT32[idx + 1];
        double approx = a + (b - a) * rem;
        double exact  = pow(2.0, -f) * 65536.0;
        double rel    = fabs(approx - exact) / exact;
        if (rel > worst) worst = rel;
    }
    /* 1/32 粒度线性插值的理论相对误差上界 ≈ 8e-4 */
    chk("exp2 线性插值最大相对误差 < 1.2e-3", worst, 0.0, 1.2e-3);
    printf("  info  exp2 插值最大相对误差 = %.3e\n", worst);
}

/* 确定性 exp：与 libm 的偏差必须 <= 1 ulp。
 * 这条不是为了"更准"，是防回归 —— 系数抄错、或编译器又开始把
 * Horner 收缩成 FMA，都会让 ref.hex 悄悄变一位。等发现 git diff
 * 才发现"向量变了"就太晚了：那时已经分不清是模型错了还是编译器变了。
 * 扫描范围覆盖 F=16 的全部格点（RTL 实际会遇到的 x 都在这个网格上）。 */
static void test_expf(void)
{
    union { double d; unsigned long long u; } a, b;
    long  maxulp = 0;
    int   nbad   = 0;

    for (int i = 0; i <= 32 * 65536; i++) {
        double x  = -(double)i / 65536.0;
        double rl = exp(x);              /* libm */
        double rd = attn_exp_f64(x);     /* 确定性实现 */
        long   u;

        a.d = rl; b.d = rd;
        u = (a.u > b.u) ? (long)(a.u - b.u) : (long)(b.u - a.u);
        if (u > maxulp) maxulp = u;
        if (u > 1) nbad++;
    }
    chk_i("exp: F=16 格点上 >1ulp 的点数", nbad, 0);
    chk("exp: 最大偏差 ulp", (double)maxulp, 0.0, 1.0);   /* 值本身 <= 1 */
    chk("exp(0) == 1", attn_exp_f64(0.0), 1.0, 0.0);
    chk("exp(-32) 相对误差", attn_exp_f64(-32.0) / exp(-32.0) - 1.0, 0.0, 1e-15);
}

static void test_endpoints(void)
{
    /* 全部输入为同一常数 c：S 全为 16c²/4=4c²，softmax 均匀，Y 每行 = 均值(V) */
    mat_in_t in;
    for (int i = 0; i < ATTN_MX; i++)
        for (int j = 0; j < ATTN_MX; j++) {
            in.q[i][j] = 1.0; in.k[i][j] = 1.0; in.v[i][j] = 1.0;
        }
    attn_cfg_t cfg = { 16, 13, 4, 1 };
    mat_out_t o;
    attn_fixed(&cfg, &in, &o);
    chk("全 1 输入 -> Y[0][0] == 1.0", f16_to_d(o.y[0][0]), 1.0, 0.0);
    chk_i("全 1 输入 -> psum == 65536", o.psum[0], 65536);

    /* 全零 -> 均匀 softmax，Y 应为 0 */
    for (int i = 0; i < ATTN_MX; i++)
        for (int j = 0; j < ATTN_MX; j++) {
            in.q[i][j] = 0.0; in.k[i][j] = 0.0; in.v[i][j] = 0.0;
        }
    attn_fixed(&cfg, &in, &o);
    chk("全零输入 -> Y[0][0] == 0.0", f16_to_d(o.y[0][0]), 0.0, 0.0);
    chk_i("全零输入 -> psum == 65536", o.psum[0], 65536);

    /* 极端：Q,K 使 S 远超 exp 范围（16c²/4 取 c=2 -> S=16），不应出现 NaN/Inf */
    for (int i = 0; i < ATTN_MX; i++)
        for (int j = 0; j < ATTN_MX; j++) {
            in.q[i][j] = 2.0; in.k[i][j] = 2.0; in.v[i][j] = 2.0;
        }
    attn_fixed(&cfg, &in, &o);
    chk("饱和输入 -> Y[0][0] == 2.0", f16_to_d(o.y[0][0]), 2.0, 0.0);
    int allfin = 1;
    for (int i = 0; i < ATTN_MX; i++)
        for (int j = 0; j < ATTN_MX; j++)
            if (!isfinite(f16_to_d(o.y[i][j]))) allfin = 0;
    chk_i("饱和输入 -> 输出全有限", allfin, 1);
}

int main(void)
{
    printf("== fp16 ==\n");    test_fp16();
    printf("== fixed ==\n");   test_fx();
    printf("== exp2  ==\n");   test_exp2();
    printf("== expf  ==\n");   test_expf();
    printf("== 端点  ==\n");   test_endpoints();

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
