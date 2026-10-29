/* =====================================================================
 *  vecgen.h —— 六类测试向量生成器（题面 §验证要求 1 的六项）
 *
 *  所有随机量都由 seed 决定，生成结果必须可复现——
 *  报告表 1 要填「测试集版本及随机种子」。
 * ===================================================================== */
#ifndef VECGEN_H
#define VECGEN_H

#include "attn_model.h"
#include <stdint.h>

typedef enum {
    CAT_RANDOM = 0,   /* 随机数据 */
    CAT_ZERO,         /* 全零 */
    CAT_EXTREME,      /* 规定范围的正负极值 */
    CAT_CANCEL,       /* 相消数据 */
    CAT_RESET,        /* 复位及恢复 */
    CAT_CONT,         /* 连续任务 */
    CAT_N
} cat_t;

const char *cat_name(cat_t c);

/* 复位生成器到指定 seed（确定性） */
void vec_seed(uint64_t seed);

/* 生成第 idx 个任务（idx 用于在同一类内产生不同样本） */
void vec_make(cat_t c, int idx, mat_in_t *out);

/* 该类别建议的样本数 */
int cat_runs(cat_t c);

#endif /* VECGEN_H */
