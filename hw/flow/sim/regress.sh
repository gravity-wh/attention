#!/usr/bin/env bash
# =====================================================================
#  flow/sim/regress.sh —— 一个方案跑完六类激励（题目 §验证要求 1）
#
#  用法： bash flow/sim/regress.sh <variant> <tag> [seed] [mode]
#        mode = smoke（每类 2 个任务，用于日常迭代）
#             = full （随机/极值/相消 各 200，复位/连续 按模型设定）
#
#  顺序有意义：先 random 抓到大批量问题，再极值打饱和，再相消打精度，
#  最后 reset/cont 查状态泄漏。前面挂了就别看后面，先修。
#
#  退出码：全部 PASS 才 0
# =====================================================================
set -uo pipefail

VARIANT=${1:?用法: regress.sh <variant> <tag> [seed] [mode]}
TAG=${2:?}
SEED=${3:-20260101}
MODE=${4:-smoke}
CLOCK=${5:-100}
export MODE

case "$MODE" in
    smoke) N_random=2; N_zero=2; N_extreme=2; N_cancel=2; N_reset=2; N_cont=2 ;;
    full)  N_random=200; N_zero=4; N_extreme=200; N_cancel=200; N_reset=4; N_cont=8 ;;
    *) echo "✗ mode 只能是 smoke 或 full"; exit 1 ;;
esac

SUF=""
[ "$MODE" = "full" ] && SUF="_full"
VECDIR="tb/vectors/s$SEED$SUF"

echo "================================================================"
echo " 回归：variant=$VARIANT  tag=$TAG  seed=$SEED  mode=$MODE"
echo "================================================================"

bash flow/sim/build.sh "$VARIANT" "$TAG" "$CLOCK" || exit 1

# 覆盖率和向量都要先就绪
if [ ! -d "$VECDIR" ]; then
    echo "[regress] 向量缺失，先导出（mode=$MODE）"
    bash flow/sim/genvec.sh "$SEED" "$MODE" || exit 1
fi

FAILED=""
for cat in random zero extreme cancel reset cont; do
    var="N_$cat"
    n=${!var}
    if ! bash flow/sim/run.sh "$VARIANT" "$TAG" "$cat" "$n" "$SEED" 0; then
        FAILED="$FAILED $cat"
    fi
done

echo "================================================================"
if [ -z "$FAILED" ]; then
    echo " 全部通过 ✓   → runs/$TAG/summary.csv"
    exit 0
else
    echo " 未通过:$FAILED"
    echo " 逐个看日志： runs/$TAG/sim_<cat>.log"
    exit 1
fi
