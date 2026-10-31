#!/usr/bin/env bash
# =====================================================================
#  flow/pnr/run_pnr.sh —— 调用 Innovus 跑全流程
#
#  正常入口是 `make pnr VARIANT=ref TAG=ref-sm40 PDK=SC9MC`：
#  Makefile 负责把 config/pdk.mk 里的库路径、qrc、tech LEF 全部导出，
#  本脚本只做前置检查和落地日志，不自己解释配置（避免两处真相）。
# =====================================================================
set -uo pipefail

die() { echo "✗ $*" >&2; exit 1; }

for v in PNR_TECH_LEF PNR_CELL_LEF PNR_NETLIST PNR_TOP PNR_OUT \
         PNR_MMMC PNR_LIB_TT PNR_LIB_SS PNR_LIB_FF \
         PNR_QRC_TT PNR_QRC_SS PNR_QRC_FF PNR_SDC; do
    [ -n "${!v:-}" ] || die "缺环境变量 $v —— 请用 make pnr 调用"
done

command -v innovus >/dev/null || die "找不到 innovus"

for f in "$PNR_TECH_LEF" "$PNR_CELL_LEF" "$PNR_NETLIST" "$PNR_SDC" "$PNR_MMMC"; do
    [ -f "$f" ] || die "找不到输入文件: $f"
done

# 两个 innovus 并行会互相抢 license 和 CPU，且 DRC 结果不可信
if pgrep -x innovus >/dev/null 2>&1; then
    echo "✗ 已有 innovus 在跑：" >&2
    pgrep -a -x innovus >&2
    die "先等它结束或 pkill -9 -x innovus"
fi

mkdir -p "$PNR_OUT"
echo "[pnr] top=$PNR_TOP"
echo "[pnr] netlist=$PNR_NETLIST"
echo "[pnr] tech LEF=$PNR_TECH_LEF"
echo "[pnr] cell LEF=$PNR_CELL_LEF"
echo "[pnr] out=$PNR_OUT"

cd "$(dirname "$0")/../.." || die "进不去 hw/ 目录"

timeout 14400 innovus -no_gui -files flow/pnr/pnr.tcl 2>&1 | tee "$PNR_OUT/pnr.log"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || die "innovus 退出码 $rc（见 $PNR_OUT/pnr.log）"
grep -q "\[pnr\] ========== DONE ==========" "$PNR_OUT/pnr.log" \
    || die "流程没跑到 DONE（见 $PNR_OUT/pnr.log 末尾）"

echo "[pnr] ✓ 完成：$PNR_OUT"
