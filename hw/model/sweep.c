/* =====================================================================
 *  sweep.c —— 只扫小数位 qf，看误差随位宽的曲线
 *
 *  为什么单独写一个：attn_baseline 是"方案对照"，这里要的是"连续曲线"。
 *  qb 固定为 16，保证 ±4 的表示范围充足（不会饱和），
 *  于是 qb 只起容器作用，真正变化的变量只有 qf —— 单变量干净。
 *
 *  输出 CSV，可直接喂给画图脚本（报告用的"精度-位宽"曲线）。
 * ===================================================================== */
#include "attn_model.h"
#include "fp16.h"
#include "vecgen.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define LIM_RMSE 0.06
#define LIM_AE   0.20

static void eval(const attn_cfg_t *cfg, const mat_in_t *in,
                 double *rmse, double *ae)
{
    mat_out_t o;
    double ref[ATTN_MX][ATTN_MX];
    attn_fixed(cfg, in, &o);
    attn_ref(in, ref);
    double se = 0.0, mx = 0.0;
    for (int i = 0; i < ATTN_MX; i++)
        for (int j = 0; j < ATTN_MX; j++) {
            double y = f16_to_d(o.y[i][j]);
            double e = y - ref[i][j];
            se += e * e;
            if (fabs(e) > mx) mx = fabs(e);
        }
    *rmse = sqrt(se / (double)(ATTN_MX * ATTN_MX));
    *ae   = mx;
}

int main(int argc, char **argv)
{
    uint64_t seed = (argc > 1) ? strtoull(argv[1], NULL, 10) : 20260101ULL;
    int      lut  = (argc > 2) ? atoi(argv[2]) : 4;

    printf("qf,qb,qb_eff,lsb,rmse_random,ae_random,rmse_cancel,ae_cancel,"
           "rmse_worst,ae_worst,pass\n");

    for (int qf = 4; qf <= 13; qf++) {
        attn_cfg_t cfg = { 16, qf, lut, 1 };
        double wr = 0, wa = 0, rc = 0, ac = 0, rr = 0, ar = 0;

        vec_seed(seed);
        for (int i = 0; i < 200; i++) {
            mat_in_t in; double r, a;
            vec_make(CAT_RANDOM, i, &in);
            eval(&cfg, &in, &r, &a);
            if (r > rr) rr = r;
            if (a > ar) ar = a;
        }
        vec_seed(seed + 200003u);
        for (int i = 0; i < 200; i++) {
            mat_in_t in; double r, a;
            vec_make(CAT_CANCEL, i, &in);
            eval(&cfg, &in, &r, &a);
            if (r > rc) rc = r;
            if (a > ac) ac = a;
        }
        wr = (rr > rc) ? rr : rc;
        wa = (ar > ac) ? ar : ac;

        printf("%d,16,%d,%.3e,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%s\n",
               qf, qf + 3, ldexp(1.0, -qf), rr, ar, rc, ac, wr, wa,
               (wr <= LIM_RMSE && wa <= LIM_AE) ? "Y" : "N");
    }
    return 0;
}
