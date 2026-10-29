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
 *    <cat>_<idx>_qkv.hex              768 个 16bit  Q[0..255] K[256..511] V[512..767]
 *                                                  行主序，元素 (i,j) 在 i*16+j
 *    <cat>_<idx>_exp_<cfg>.hex        256 个 16bit  期望输出 Y（FP16 位模式，逐位比对）
 *    <cat>_<idx>_ref.hex              256 个 64bit  float64 参考（RMSE / 最大误差用）
 *
 *  <cfg> = qb<QB>qf<QF>，例如 qb10qf7。
 *  为什么 exp 要带格式标签、qkv/ref 不带：
 *    qkv 是输入、ref 只取决于输入，两者与内部数值格式无关，三个方案共享同一份；
 *    exp 是"该格式下应得的结果"，ref(16bit) 与 varA(10bit) 必然不同。
 *    不分开命名的话，后跑的方案会静默覆盖前一个的黄金值，
 *    tb 会拿 varA 的输出跟 ref 的期望比，报一堆看起来像 RTL bug 的失配。
 *
 *  另有 manifest.txt 记录 seed、定点配置、任务清单与每行 Σp。
 *  manifest 只写确定性的内容（不含时间戳/主机名），这样同一 seed 重跑
 *  在 git 里是零 diff；生成环境另外记在 geninfo.txt。
 *
 *  用法：
 *    attn_dumpvec <seed> <outdir> <smoke|full> <qb> <qf> <lut>
 *    attn_dumpvec --check <seed> <outdir> <mode> <qb> <qf> <lut>
 *        不写文件，把磁盘上的向量读回来与重算结果逐值比对（make vecfsck）。
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

static void cfg_tag(char *buf, size_t n, const attn_cfg_t *c)
{
    snprintf(buf, n, "qb%dqf%d", c->qb, c->qf);
}

/* ---------------------------------------------------------------- 写文件 */
static FILE *openw(const char *dir, const char *base, const char *suffix)
{
    char path[1024];
    FILE *fp;
    snprintf(path, sizeof(path), "%s/%s%s", dir, base, suffix);
    fp = fopen(path, "w");
    if (!fp) { perror(path); exit(1); }
    return fp;
}

/* ------------------------------------------------------------ 回读比对
 * 逐 token 比较整数，不做浮点解析：hex 文本就是位模式，
 * 走一遍 strtod 只会引入"看起来相等其实舍入过"的新风险。
 * 返回不一致的元素个数；*first 给出首个不一致的下标（无则 -1）。 */
static int verify_hex(const char *dir, const char *base, const char *suffix,
                      const uint64_t *want, int n, int width, int *first)
{
    char   path[1024];
    FILE  *fp;
    int    i, bad = 0;
    *first = -1;

    snprintf(path, sizeof(path), "%s/%s%s", dir, base, suffix);
    fp = fopen(path, "r");
    if (!fp) {
        printf("  ✗ 缺失: %s\n", path);
        return n;
    }
    for (i = 0; i < n; i++) {
        char     tok[64];
        uint64_t got;

        if (fscanf(fp, "%63s", tok) != 1) {
            if (*first < 0) *first = i;
            bad += n - i;                 /* 文件短了，剩下全算缺失 */
            break;
        }
        got = strtoull(tok, NULL, 16);
        if (got != want[i]) {
            if (*first < 0) { *first = i;
                printf("  ✗ %s%s 第 %d 个不符: 文件 %0*llx 模型 %0*llx\n",
                       base, suffix, i, width, (unsigned long long)got,
                       width, (unsigned long long)want[i]); }
            bad++;
        }
    }
    /* 多出来的行也算异常：说明文件是另一个任务的残留 */
    if (bad == 0) {
        char extra[64];
        if (fscanf(fp, "%63s", extra) == 1) {
            printf("  ✗ %s%s 行数多于预期（%d），文件可能拼接了别的任务\n",
                   base, suffix, n);
            bad++;
        }
    }
    fclose(fp);
    return bad;
}

int main(int argc, char **argv)
{
    uint64_t     seed;
    const char  *dir;
    int          full, check = 0, ai = 0;
    attn_cfg_t   cfg;
    FILE        *man = NULL;
    char         path[1024], tag[32];
    int          ntask = 0, nbad = 0;

    /* --check 时不写任何文件，参数整体后移一位 */
    if (argc > 1 && strcmp(argv[1], "--check") == 0) { check = 1; ai = 1; }

    if (argc < ai + 4) {
        fprintf(stderr,
                "用法: %s <seed> <outdir> <smoke|full> <qb> <qf> <lut>\n"
                "      %s --check <seed> <outdir> <smoke|full> <qb> <qf> <lut>\n",
                argv[0], argv[0]);
        return 1;
    }
    seed = strtoull(argv[ai + 1], NULL, 10);
    dir  = argv[ai + 2];
    full = (strcmp(argv[ai + 3], "full") == 0);

    /* 格式必须由调用方显式给出。早期版本在这里留了 {16,13,4,1} 的默认值，
     * 结果 genvec.sh 换方案时忘了传参，向量就静默按 16bit 生成，
     * 而 RTL 按 10bit 综合 —— 这种失配在 tb 里表现为"全是 RTL bug"，极难查。
     * 宁可在这里报错退出。 */
    if (argc < ai + 7) {
        fprintf(stderr, "✗ 必须显式给出 qb qf lut（见 config/variants.mk）\n");
        return 1;
    }
    cfg.qb       = atoi(argv[ai + 4]);
    cfg.qf       = atoi(argv[ai + 5]);
    cfg.lut_bits = atoi(argv[ai + 6]);
    cfg.approx   = 1;
    if (cfg.qf >= cfg.qb || cfg.lut_bits < 2 || cfg.lut_bits > 5) {
        fprintf(stderr, "✗ 格式参数不合理: qb=%d qf=%d lut=%d\n",
                cfg.qb, cfg.qf, cfg.lut_bits);
        return 1;
    }
    cfg_tag(tag, sizeof(tag), &cfg);

    if (!check) {
        snprintf(path, sizeof(path), "%s/manifest.txt", dir);
        man = fopen(path, "w");
        if (!man) { perror(path); return 1; }

        fprintf(man, "# RTL 测试向量清单（确定性内容，不含时间戳；生成环境见 geninfo.txt）\n");
        fprintf(man, "format    : ATTN_VEC_2\n");
        fprintf(man, "seed      : %llu\n", (unsigned long long)seed);
        fprintf(man, "cfg_tag   : %s\n", tag);
        fprintf(man, "cfg_qb    : %d\n", cfg.qb);
        fprintf(man, "cfg_qf    : %d\n", cfg.qf);
        fprintf(man, "cfg_lut   : %d\n", cfg.lut_bits);
        fprintf(man, "cfg_approx: %d\n", cfg.approx);
        fprintf(man, "matrix    : %dx%d, 行主序, 元素 (i,j) 位于 i*%d+j\n",
                ATTN_MX, ATTN_MX, ATTN_MX);
        fprintf(man, "qkv.hex   : 768 个 16bit — Q[0..255] K[256..511] V[512..767]（与格式无关，全方案共享）\n");
        fprintf(man, "exp.hex   : 256 个 16bit — %s 格式下逐位一致的期望输出\n", tag);
        fprintf(man, "ref.hex   : 256 个 64bit — float64 参考（RMSE 用，与格式无关）\n");
        fprintf(man, "#\n");
        fprintf(man, "# 以下每行一个任务：<文件基名> <类别> <行Σp 最小值> <行Σp 最大值>\n");
        fprintf(man, "# 行Σp 理想值 65536（Q16），偏离量就是倒数单元的体检结果\n");
    } else {
        printf("[fsck] 校验 %s  格式=%s  mode=%s\n",
               dir, tag, full ? "full" : "smoke");
    }

    for (int c = 0; c < CAT_N; c++) {
        cat_t cat = (cat_t)c;
        int runs = cat_runs(cat);
        if (!full && runs > 2) runs = 2;      /* smoke：每类取前 2 个 */

        for (int idx = 0; idx < runs; idx++) {
            mat_in_t  in;
            mat_out_t out;
            double    ref[ATTN_MX][ATTN_MX];
            char      base[128];
            uint64_t  vqkv[3 * ATTN_MX * ATTN_MX];
            uint64_t  vexp[ATTN_MX * ATTN_MX];
            uint64_t  vref[ATTN_MX * ATTN_MX];
            int       pmin = 0x7FFFFFFF, pmax = -0x7FFFFFFF;
            int       n, first;

            /* 与 main.c 的取种子方式保持逐位一致：同一 seed 下
             * 模型自检与向量导出看到的是同一批输入。 */
            if (cat == CAT_RESET)      vec_seed(seed + (uint64_t)idx * 7919u);
            else if (cat == CAT_CONT)  vec_seed(seed + 1000003u);
            else                       vec_seed(seed + (uint64_t)cat * 100003u);

            vec_make(cat, idx, &in);
            attn_fixed(&cfg, &in, &out);
            attn_ref(&in, ref);

            snprintf(base, sizeof(base), "%s_%d", cat_slug(cat), idx);

            n = 0;
            for (int i = 0; i < ATTN_MX; i++)
                for (int j = 0; j < ATTN_MX; j++) vqkv[n++] = d_to_f16(in.q[i][j]);
            for (int i = 0; i < ATTN_MX; i++)
                for (int j = 0; j < ATTN_MX; j++) vqkv[n++] = d_to_f16(in.k[i][j]);
            for (int i = 0; i < ATTN_MX; i++)
                for (int j = 0; j < ATTN_MX; j++) vqkv[n++] = d_to_f16(in.v[i][j]);

            for (int i = 0; i < ATTN_MX * ATTN_MX; i++)
                vexp[i] = out.y[i / ATTN_MX][i % ATTN_MX];

            for (int i = 0; i < ATTN_MX * ATTN_MX; i++) {
                union { double d; uint64_t u; } cv;
                cv.d = ref[i / ATTN_MX][i % ATTN_MX];
                vref[i] = cv.u;
            }

            if (check) {
                char esuf[48];
                nbad += verify_hex(dir, base, "_qkv.hex", vqkv, 3 * ATTN_MX * ATTN_MX, 4, &first);
                snprintf(esuf, sizeof(esuf), "_exp_%s.hex", tag);
                nbad += verify_hex(dir, base, esuf, vexp, ATTN_MX * ATTN_MX, 4, &first);
                nbad += verify_hex(dir, base, "_ref.hex", vref, ATTN_MX * ATTN_MX, 16, &first);
            } else {
                FILE *fqkv = openw(dir, base, "_qkv.hex");
                for (int i = 0; i < 3 * ATTN_MX * ATTN_MX; i++) fprintf(fqkv, "%04llx\n",
                                                                       (unsigned long long)vqkv[i]);
                fclose(fqkv);

                char esuf[48];
                snprintf(esuf, sizeof(esuf), "_exp_%s.hex", tag);
                FILE *fexp = openw(dir, base, esuf);
                for (int i = 0; i < ATTN_MX * ATTN_MX; i++) fprintf(fexp, "%04llx\n",
                                                                   (unsigned long long)vexp[i]);
                fclose(fexp);

                FILE *fref = openw(dir, base, "_ref.hex");
                for (int i = 0; i < ATTN_MX * ATTN_MX; i++) fprintf(fref, "%016llx\n",
                                                                    (unsigned long long)vref[i]);
                fclose(fref);
            }

            for (int i = 0; i < ATTN_MX; i++) {
                if (out.psum[i] < pmin) pmin = out.psum[i];
                if (out.psum[i] > pmax) pmax = out.psum[i];
            }
            if (!check) fprintf(man, "%-16s %-14s %8d %8d\n", base, cat_name(cat), pmin, pmax);
            ntask++;
        }
    }

    if (!check) {
        fprintf(man, "#\n# 任务总数: %d\n", ntask);
        fclose(man);
        printf("→ %d 个任务写入 %s\n", ntask, dir);
        printf("  seed=%llu  cfg=%s (qb=%d qf=%d lut=%d approx=%d)\n",
               (unsigned long long)seed, tag, cfg.qb, cfg.qf, cfg.lut_bits, cfg.approx);
    } else if (nbad == 0) {
        printf("[fsck] ✓ %d 个任务 × 3 个文件全部与模型一致\n", ntask);
    } else {
        printf("[fsck] ✗ 共 %d 处不一致 —— 向量已过期或文件被改过，重跑 make vec\n", nbad);
    }
    return check && nbad ? 1 : 0;
}
