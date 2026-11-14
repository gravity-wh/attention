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

# 向量必须按"数值格式"逐份检查，不能只看目录在不在。
# exp 的黄金值文件名带格式标签：_exp_qb<QB>qf<QF>.hex，清单是 geninfo_qb<QB>qf<QF>.txt。
# ref 用 qb16qf13、varA 用 qb10qf7、varB 用 qb10qf7 —— 同一 seed 下是两套不同文件。
# 旧逻辑只看 $VECDIR 是否存在，于是先跑的 ref 把目录建出来之后，
# varA 六类激励全部因 'random_0_exp_qb10qf7.hex 打不开' 而 FAIL（2026-11-12 实测踩到）。
: "${CFGTAG:?未设置 CFGTAG —— 请用 make regress/pair 调用（值来自 config/variants.mk）}"
if [ ! -f "$VECDIR/geninfo_${CFGTAG}.txt" ]; then
    echo "[regress] 向量缺失（cfg=$CFGTAG），先导出（mode=$MODE）"
    bash flow/sim/genvec.sh "$SEED" "$MODE" || exit 1
fi

# 编译放在向量检查之后：先确认要用的黄金值存在，再花 5 分钟编 simv
bash flow/sim/build.sh "$VARIANT" "$TAG" "$CLOCK" || exit 1

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
