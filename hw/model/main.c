/* =====================================================================
 *  main.c —— 误差基线驱动
 *
 *  跑的事：
 *    对每个定点配置 × 六类测试向量，算
 *      - 与 float64 参考的 RMSE（阈值 0.06）与最大绝对误差（阈值 0.20）
 *      - 输出是否全为有限 FP16 值
 *      - 每行 Σp 相对 1.0 的偏差（倒数单元的体检）
 *    复位/连续任务两类额外做逐位自比对。
 *
 *  用法： attn_baseline [seed] [outfile]
 * ===================================================================== */
#include "attn_model.h"
#include "fp16.h"
#include "vecgen.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RMSE_LIMIT 0.06
#define MAXAE_LIMIT 0.20

typedef struct {
    const char *name;
    attn_cfg_t  cfg;
} variant_t;

static const variant_t VARIANTS[] = {
    { "A  16b lut4",        { 16, 13, 4, 1 } },
    { "A' 16b lut4-noapp",  { 16, 13, 4, 0 } },   /* 关掉 LUT+倒数，隔离格式误差 */
    { "B  16b lut2",        { 16, 13, 2, 1 } },
    { "C  14b lut4",        { 14, 11, 4, 1 } },
    { "D  13b lut4",        { 13, 10, 4, 1 } },
    { "E  12b lut4",        { 12,  9, 4, 1 } },
    { "F  12b lut3",        { 12,  9, 3, 1 } },
    { "G  12b lut2",        { 12,  9, 2, 1 } },
    { "H  11b lut3",        { 11,  8, 3, 1 } },
    { "I  10b lut4",        { 10,  7, 4, 1 } },
    { "J  10b lut3",        { 10,  7, 3, 1 } },
    { "K   8b lut2",        {  8,  5, 2, 1 } },   /* 负对照：看 8 bit 到底够不够 */
};
#define NVAR ((int)(sizeof(VARIANTS) / sizeof(VARIANTS[0])))

typedef struct {
    double max_rmse;     /* 各类中最大的单帧 RMSE */
    double max_ae;       /* 各类中最大的单元素绝对误差 */
    double max_psum;     /* 行和偏差，单位：LSB(1/65536) */
    int    nfinite_bad;  /* 出现非有限值的任务数 */
    int    nbitdiff;     /* 复位/连续任务里逐位不一致的任务数 */
    int    runs;
} cat_stat_t;

/* 单个任务：模型 vs float64 参考 */
static void eval_one(const attn_cfg_t *cfg, const mat_in_t *in,
                     double *rmse, double *maxae, int *finite_bad, double *psum_dev)
{
    mat_out_t o;
    double    ref[ATTN_MX][ATTN_MX];
    int       i, j;

    attn_fixed(cfg, in, &o);
    attn_ref(in, ref);

    double se = 0.0, mx = 0.0;
    int    bad = 0;
    for (i = 0; i < ATTN_MX; i++) {
        for (j = 0; j < ATTN_MX; j++) {
            double y = f16_to_d(o.y[i][j]);
            if (!isfinite(y)) { bad = 1; continue; }
            double e = y - ref[i][j];
            se += e * e;
            if (fabs(e) > mx) mx = fabs(e);
        }
    }
    *rmse       = sqrt(se / (double)(ATTN_MX * ATTN_MX));
    *maxae      = mx;
    *finite_bad = bad;

    double pd = 0.0;
    for (i = 0; i < ATTN_MX; i++) {
        double d = fabs((double)o.psum[i] - 65536.0);
        if (d > pd) pd = d;
    }
    *psum_dev = pd;
}

static void bump(cat_stat_t *s, double rmse, double ae, int fbad, int bdiff, double pd)
{
    if (rmse > s->max_rmse) s->max_rmse = rmse;
    if (ae   > s->max_ae)   s->max_ae   = ae;
    if (pd   > s->max_psum) s->max_psum = pd;
    s->nfinite_bad += fbad;
    s->nbitdiff    += bdiff;
    s->runs        += 1;
}

static void run_category(const attn_cfg_t *cfg, cat_t cat, uint64_t seed, cat_stat_t *st)
{
    int   n = cat_runs(cat);
    int   i;

    memset(st, 0, sizeof(*st));

    if (cat == CAT_RESET) {
        /* 跑一次 -> 复位 -> 同一个任务再跑一次，两次输出必须逐位相同 */
        for (i = 0; i < n; i++) {
            mat_in_t  in;
            mat_out_t a, b;
            double    rmse, ae, pd;
            int       fbad, bdiff;

            vec_seed(seed + (uint64_t)i * 7919u);
            vec_make(cat, i, &in);

            attn_fixed(cfg, &in, &a);
            attn_reset();
            attn_fixed(cfg, &in, &b);

            bdiff = (memcmp(&a, &b, sizeof(a)) != 0);
            eval_one(cfg, &in, &rmse, &ae, &fbad, &pd);
            bump(st, rmse, ae, fbad, bdiff, pd);
        }
        return;
    }

    if (cat == CAT_CONT) {
        /* 连续 n 个任务，不复位，每个都要和"单独跑"的结果逐位一致 */
        vec_seed(seed + 1000003u);
        for (i = 0; i < n; i++) {
            mat_in_t  in;
            mat_out_t chain, solo;
            double    rmse, ae, pd;
            int       fbad, bdiff;

            vec_make(cat, i, &in);
            attn_fixed(cfg, &in, &chain);      /* 在"脏"状态下算 */
            attn_reset();
            attn_fixed(cfg, &in, &solo);       /* 干净状态下算 */

            bdiff = (memcmp(&chain, &solo, sizeof(chain)) != 0);
            eval_one(cfg, &in, &rmse, &ae, &fbad, &pd);
            bump(st, rmse, ae, fbad, bdiff, pd);
        }
        return;
    }

    vec_seed(seed + (uint64_t)cat * 100003u);
    for (i = 0; i < n; i++) {
        mat_in_t in;
        double   rmse, ae, pd;
        int      fbad;

        vec_make(cat, i, &in);
        eval_one(cfg, &in, &rmse, &ae, &fbad, &pd);
        bump(st, rmse, ae, fbad, 0, pd);
    }
}

int main(int argc, char **argv)
{
    uint64_t seed = 20260101ULL;
    FILE    *fp   = stdout;

    if (argc > 1) seed = strtoull(argv[1], NULL, 10);
    if (argc > 2) {
        fp = fopen(argv[2], "w");
        if (!fp) { perror("fopen"); return 1; }
    }

    fprintf(fp, "# 定点注意力模型 · 误差基线\n");
    fprintf(fp, "# seed = %llu\n", (unsigned long long)seed);
    fprintf(fp, "# 判据 RMSE <= %.3f, 最大绝对误差 <= %.3f（对 float64 参考）\n",
            RMSE_LIMIT, MAXAE_LIMIT);
    fprintf(fp, "\n");

    fprintf(fp, "%-18s %3s %3s %4s  %-14s %5s %10s %10s %8s %9s %5s  %s\n",
            "variant", "qb", "qf", "lut", "category", "runs",
            "maxRMSE", "max|err|", "psum_dev", "bitdiff", "finite", "verdict");
    fprintf(fp, "%s\n", "-----------------------------------------------------------------------------------------------------------------------------------------");

    int total_bad = 0;

    for (int v = 0; v < NVAR; v++) {
        const attn_cfg_t *cfg = &VARIANTS[v].cfg;
        cat_stat_t agg;
        memset(&agg, 0, sizeof(agg));

        for (int c = 0; c < CAT_N; c++) {
            cat_stat_t st;
            run_category(cfg, (cat_t)c, seed, &st);

            int pass = (st.max_rmse <= RMSE_LIMIT) &&
                       (st.max_ae   <= MAXAE_LIMIT) &&
                       (st.nfinite_bad == 0) &&
                       (st.nbitdiff == 0);

            fprintf(fp, "%-18s %3d %3d %4d  %-14s %5d %10.6f %10.6f %8.1f %9d %5s  %s\n",
                    VARIANTS[v].name, cfg->qb, cfg->qf, cfg->lut_bits,
                    cat_name((cat_t)c), st.runs,
                    st.max_rmse, st.max_ae, st.max_psum,
                    st.nbitdiff,
                    st.nfinite_bad ? "NO" : "yes",
                    pass ? "PASS" : "FAIL");

            if (!pass) total_bad++;
            if (st.max_rmse > agg.max_rmse) agg.max_rmse = st.max_rmse;
            if (st.max_ae   > agg.max_ae)   agg.max_ae   = st.max_ae;
        }

        fprintf(fp, "%-18s %3d %3d %4d  %-14s %5s %10.6f %10.6f %8s %9s %5s  %s\n",
                VARIANTS[v].name, cfg->qb, cfg->qf, cfg->lut_bits,
                "== ALL ==", "", agg.max_rmse, agg.max_ae, "", "", "",
                (agg.max_rmse <= RMSE_LIMIT && agg.max_ae <= MAXAE_LIMIT) ? "PASS" : "FAIL");
        fprintf(fp, "\n");
    }

    fprintf(fp, "# 汇总：%d 个 (variant,category) 组合未通过\n", total_bad);

    if (fp != stdout) fclose(fp);
    return total_bad ? 2 : 0;
}
