/* =====================================================================
 *  dumpvec.c —— 把黄金模型导出成 RTL testbench 直接可读的十六进制向量
 *
 *  为什么用 C 而不是 Python 重写一遍：
 *    向量必须与「逐位一致模型」出自同一份代码。只要用别的语言重算一遍，
 *    就多了一条可能不一致的路径——而这恰恰是"逐位一致"这项要被扣分的地方。
 *
 *  ── 输出契约（tb 依赖它，改格式等于改 tb）────────────────────────────
 *  每个任务三个文件，全部 $readmemh 可读、每行一个值：
 *
 *    <cat>_<idx>_qkv.hex   768 个 16bit   Q[0..255] K[256..511] V[512..767]
 *                                        行主序，Y[i][j] 在 i*16+j
 *    <cat>_<idx>_exp.hex   256 个 16bit   期望输出 Y（FP16 位模式，逐位比对）
 *    <cat>_<idx>_ref.hex   256 个 64bit   float64 参考值（RMSE / 最大误差用）
 *
 *  另有 manifest.txt 记录 seed、定点配置、任务清单与每行 Σp。
 *
 *  用法：
 *    attn_dumpvec <seed> <outdir> <smoke|full> [qb] [qf] [lut]
 * ===================================================================== */
#include "attn_model.h"
#include "fp16.h"
#include "vecgen.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 文件名里用的短名：cat_name() 返回的是给人看的，带空格/连字符，
 * 文件名用下面这套固定短名，tb 侧按同一张表拼路径。 */
static const char *cat_slug(cat_t c)
{
    switch (c) {
    case CAT_RANDOM:  return "random";
    case CAT_ZERO:    return "zero";
    case CAT_EXTREME: return "extreme";
    case CAT_CANCEL:  return "cancel";
    case CAT_RESET:   return "reset";
    case CAT_CONT:    return "cont";
    default:          return "other";
    }
}

static FILE *openw(const char *dir, const char *base, const char *suffix)
{
    char path[1024];
    FILE *fp;
    snprintf(path, sizeof(path), "%s/%s%s", dir, base, suffix);
    fp = fopen(path, "w");
    if (!fp) { perror(path); exit(1); }
    return fp;
}

int main(int argc, char **argv)
{
    uint64_t seed;
    const char *dir;
    int full = 0;
    attn_cfg_t cfg = { 16, 13, 4, 1 };   /* 与 width_sweep 结论一致：Q3.13 + LUT4 */
    FILE *man;
    char path[1024];
    int ntask = 0;

    if (argc < 4) {
        fprintf(stderr,
                "用法: %s <seed> <outdir> <smoke|full> [qb] [qf] [lut]\n", argv[0]);
        return 1;
    }
    seed = strtoull(argv[1], NULL, 10);
    dir  = argv[2];
    full = (strcmp(argv[3], "full") == 0);
    if (argc > 4) cfg.qb = atoi(argv[4]);
    if (argc > 5) cfg.qf = atoi(argv[5]);
    if (argc > 6) cfg.lut_bits = atoi(argv[6]);

    snprintf(path, sizeof(path), "%s/manifest.txt", dir);
    man = fopen(path, "w");
    if (!man) { perror(path); return 1; }

    fprintf(man, "# RTL 测试向量清单\n");
    fprintf(man, "format    : ATTN_VEC_1\n");
    fprintf(man, "seed      : %llu\n", (unsigned long long)seed);
    fprintf(man, "cfg_qb    : %d\n", cfg.qb);
    fprintf(man, "cfg_qf    : %d\n", cfg.qf);
    fprintf(man, "cfg_lut   : %d\n", cfg.lut_bits);
    fprintf(man, "cfg_approx: %d\n", cfg.approx);
    fprintf(man, "matrix    : %dx%d, 行主序, 元素 (i,j) 位于 i*%d+j\n",
            ATTN_MX, ATTN_MX, ATTN_MX);
    fprintf(man, "qkv.hex   : 768 个 16bit — Q[0..255] K[256..511] V[512..767]\n");
    fprintf(man, "exp.hex   : 256 个 16bit — 逐位一致的期望输出\n");
    fprintf(man, "ref.hex   : 256 个 64bit — float64 参考（RMSE 用）\n");
    fprintf(man, "#\n");
    fprintf(man, "# 以下每行一个任务：<文件基名> <类别> <行Σp 最小值> <行Σp 最大值>\n");
    fprintf(man, "# 行Σp 理想值 65536（Q16），偏离量就是倒数单元的体检结果\n");

    for (int c = 0; c < CAT_N; c++) {
        cat_t cat = (cat_t)c;
        int runs = cat_runs(cat);
        if (!full && runs > 2) runs = 2;      /* smoke：每类取前 2 个 */

        for (int idx = 0; idx < runs; idx++) {
            mat_in_t  in;
            mat_out_t out;
            double    ref[ATTN_MX][ATTN_MX];
            char      base[128];
            FILE     *fqkv, *fexp, *fref;
            int       pmin = 0x7FFFFFFF, pmax = -0x7FFFFFFF;

            /* 与 main.c 的取种子方式保持逐位一致：同一 seed 下
             * 模型自检与向量导出看到的是同一批输入。 */
            if (cat == CAT_RESET)      vec_seed(seed + (uint64_t)idx * 7919u);
            else if (cat == CAT_CONT)  vec_seed(seed + 1000003u);
            else                       vec_seed(seed + (uint64_t)cat * 100003u);

            vec_make(cat, idx, &in);
            attn_fixed(&cfg, &in, &out);
            attn_ref(&in, ref);

            snprintf(base, sizeof(base), "%s_%d", cat_slug(cat), idx);

            fqkv = openw(dir, base, "_qkv.hex");
            for (int i = 0; i < ATTN_MX; i++)
                for (int j = 0; j < ATTN_MX; j++)
                    fprintf(fqkv, "%04x\n", d_to_f16(in.q[i][j]));
            for (int i = 0; i < ATTN_MX; i++)
                for (int j = 0; j < ATTN_MX; j++)
                    fprintf(fqkv, "%04x\n", d_to_f16(in.k[i][j]));
            for (int i = 0; i < ATTN_MX; i++)
                for (int j = 0; j < ATTN_MX; j++)
                    fprintf(fqkv, "%04x\n", d_to_f16(in.v[i][j]));
            fclose(fqkv);

            fexp = openw(dir, base, "_exp.hex");
            for (int i = 0; i < ATTN_MX; i++)
                for (int j = 0; j < ATTN_MX; j++)
                    fprintf(fexp, "%04x\n", out.y[i][j]);
            fclose(fexp);

            fref = openw(dir, base, "_ref.hex");
            for (int i = 0; i < ATTN_MX; i++)
                for (int j = 0; j < ATTN_MX; j++) {
                    union { double d; uint64_t u; } cv;
                    cv.d = ref[i][j];
                    fprintf(fref, "%016llx\n", (unsigned long long)cv.u);
                }
            fclose(fref);

            for (int i = 0; i < ATTN_MX; i++) {
                if (out.psum[i] < pmin) pmin = out.psum[i];
                if (out.psum[i] > pmax) pmax = out.psum[i];
            }
            fprintf(man, "%-16s %-14s %8d %8d\n", base, cat_name(cat), pmin, pmax);
            ntask++;
        }
    }

    fprintf(man, "#\n# 任务总数: %d\n", ntask);
    fclose(man);

    printf("→ %d 个任务写入 %s\n", ntask, dir);
    printf("  seed=%llu  qb=%d qf=%d lut=%d approx=%d\n",
           (unsigned long long)seed, cfg.qb, cfg.qf, cfg.lut_bits, cfg.approx);
    return 0;
}
