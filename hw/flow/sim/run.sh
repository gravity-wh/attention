#!/usr/bin/env bash
# =====================================================================
#  flow/sim/run.sh —— 跑一个 (方案 × 类别)
#
#  用法： bash flow/sim/run.sh <variant> <tag> <cat> <n> [seed] [verbose]
#  前件： build.sh 已经生成了 runs/<tag>/simv
#  产出： runs/<tag>/sim_<cat>.log   完整日志
#         runs/<tag>/summary.csv     追加一行（回归汇总用）
#
#  退出码：0=PASS，1=FAIL（make 会因此停下，这是故意的）
# =====================================================================
set -uo pipefail

VARIANT=${1:?用法: run.sh <variant> <tag> <cat> <n> [seed] [verbose]}
TAG=${2:?}
CAT=${3:?}
N=${4:?}
SEED=${5:-20260101}
VERBOSE=${6:-0}

RUN="runs/$TAG"
SIMV="$RUN/simv"
# 向量目录与 genvec.sh 保持同一套命名规则：smoke 无后缀，full 带 _full
SUF=""
[ "${MODE:-smoke}" = "full" ] && SUF="_full"
VECDIR="tb/vectors/s$SEED$SUF"
LOG="$RUN/sim_$CAT.log"

if [ ! -x "$SIMV" ]; then
    echo "✗ 没有 $SIMV，先跑 build.sh"
    exit 1
fi
if [ ! -d "$VECDIR" ]; then
    echo "✗ 向量目录不存在: $VECDIR（先 make vec SEED=$SEED MODE=${MODE:-smoke}）"
    exit 1
fi

CM_OPTS=$(cat "$RUN/cm_opts.txt" 2>/dev/null || echo "")
CM_RUN=""
[ -n "$CM_OPTS" ] && CM_RUN="$CM_OPTS -cm_name ${VARIANT}_${TAG}_${CAT}"

# 数值格式标签由 make 从 config/variants.mk 传来，决定读哪个 _exp_<cfg>.hex。
# 这里不设默认值：默认值一旦和 RTL 的实际格式不一致，tb 会报"逐位全错"，
# 而这种假故障排查起来比真 bug 贵得多。
: "${CFGTAG:?未设置 CFGTAG —— 请用 make sim/regress 调用}"

echo "[run] $VARIANT/$CAT  n=$N  seed=$SEED  vec=$VECDIR  cfg=$CFGTAG"

"$SIMV" \
    +VECDIR="$VECDIR" \
    +CFG="$CFGTAG" \
    +CAT="$CAT" \
    +N="$N" \
    +VERBOSE="$VERBOSE" \
    $CM_RUN \
    -l "$LOG" 2>&1 | tee "$LOG.stdout" | grep -vE '^$'
RC=${PIPESTATUS[0]}

# ---- 准备阶段异常（向量缺失、文件不完整）先单独报，别混进 PASS/FAIL 统计 ----
if grep -q '^\[FATAL\]' "$LOG" 2>/dev/null; then
    grep -m3 '^\[FATAL\]' "$LOG"
    echo "✗ 仿真在准备阶段就退出了（向量或环境问题，不是 RTL 的问题）"
    exit 1
fi

# ---- 从机器可读汇总行提取指标 ----
LINE=$(grep -m1 '^\[SUMMARY\]' "$LOG" 2>/dev/null || true)
if [ -z "$LINE" ]; then
    echo "✗ 日志里没有 [SUMMARY] 行，仿真可能在启动阶段就崩了。看 $LOG"
    tail -20 "$LOG" 2>/dev/null
    exit 1
fi

get() { echo "$LINE" | sed -n "s/.*[ ]$1=\([^ ]*\).*/\1/p"; }

TASKS=$(get tasks); PASS=$(get pass); FAIL=$(get fail)
LMIN=$(get lat_min); LAVG=$(get lat_avg); LMAX=$(get lat_max)
RMSE=$(get rmse); MAXAE=$(get maxae); MIS=$(get mism); STATUS=$(get status)

echo "$TAG,$VARIANT,$CAT,$TASKS,$PASS,$FAIL,$LMIN,$LAVG,$LMAX,$RMSE,$MAXAE,$MIS,$STATUS" \
    >> "$RUN/summary.csv"

printf "[run] %-8s %-12s %s  (pass %s/%s, lat %s/%s/%s, rmse %s, max|e| %s, mism %s)\n" \
    "$VARIANT" "$CAT" "$STATUS" "$PASS" "$TASKS" "$LMIN" "$LAVG" "$LMAX" "$RMSE" "$MAXAE" "$MIS"

[ "$STATUS" = "PASS" ] || exit 1
exit 0
