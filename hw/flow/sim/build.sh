#!/usr/bin/env bash
# =====================================================================
#  flow/sim/build.sh —— 编译一个方案的仿真可执行文件
#
#  用法： bash flow/sim/build.sh <variant> <tag> [clock_mhz]
#  产出： runs/<tag>/simv      （可执行）
#         runs/<tag>/build.log  （完整编译日志 → 复现凭据）
#
#  只在方案或公共代码改动后才需要重编；同一 tag 下跑多个类别共用这一个 simv，
#  这是回归能快起来的原因。
# =====================================================================
set -uo pipefail

VARIANT=${1:?用法: build.sh <variant> <tag> [clock_mhz]}
TAG=${2:?用法: build.sh <variant> <tag> [clock_mhz]}
CLOCK=${3:-100}

RUN="runs/$TAG"
FLIST="rtl/$VARIANT/filelist.f"
TOP="top_$VARIANT"

if [ ! -f "$FLIST" ]; then
    echo "✗ 找不到 filelist: $FLIST"
    exit 1
fi

# 方案还没写时给出明确提示，而不是让 VCS 抛一堆 top_xxx 未定义的语法错误
if ! grep -qE "^[[:space:]]*rtl/$VARIANT/top_$VARIANT\.sv" "$FLIST"; then
    echo "✗ $FLIST 里没有启用的 rtl/$VARIANT/top_$VARIANT.sv"
    echo "  → 这个方案还没写。先用 make flowtest 确认流程可用，再去写 RTL。"
    exit 1
fi

mkdir -p "$RUN"

# 覆盖率：默认关。
# 实测这台机器的 Synopsys license **不含 URG 特性**（urg 一启动就在
# covdb_get_license 处崩），所以 -cm 采得到数据但出不了报告，只是白白拖慢仿真。
# 需要行/条件覆盖率时显式开：CM=1 make sim ...
CM_OPTS=""
if [ "${CM:-0}" = "1" ]; then
    CM_OPTS="-cm line+cond+fsm+tgl+branch"
fi

build() {
    local cm="$1"
    vcs -full64 -sverilog -timescale=1ns/1ps \
        -debug_access+all -kdb \
        -line \
        $cm \
        -pvalue+tb_attn.CLK_MHZ="$CLOCK" \
        +define+DUT="$TOP" \
        "+define+DUT_NAME=\"$TOP\"" \
        -f "$FLIST" \
        tb/common/attn_tb_pkg.sv \
        tb/sys/tb_attn.sv \
        -Mdir="$RUN/csrc" \
        -o "$RUN/simv" \
        -l "$RUN/build.log"
}

echo "[build] variant=$VARIANT top=$TOP clk=${CLOCK}MHz → $RUN/simv"

if build "$CM_OPTS"; then
    echo "[build] ✓ 编译通过${CM_OPTS:+（含覆盖率采集）}"
else
    echo "[build] ✗ 编译失败，见 $RUN/build.log"
    grep -iE "Error-|error:|Fatal" "$RUN/build.log" | head -10
    tail -20 "$RUN/build.log"
    exit 1
fi

echo "$CM_OPTS" > "$RUN/cm_opts.txt"

# 汇总表表头（只写一次）
if [ ! -f "$RUN/summary.csv" ]; then
    echo "tag,variant,cat,tasks,pass,fail,lat_min,lat_avg,lat_max,worst_rmse,worst_maxae,mismatch,status" \
        > "$RUN/summary.csv"
fi

echo "[build] 完成"
exit 0
