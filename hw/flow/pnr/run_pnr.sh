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


# ---- 按实际内存选线程数（实测标定，非拍脑袋）-------------------------
# 实测（69k 单元，信号层 M2-M5）：
#   布线内存 ≈ 5 GB 基线（设计规模决定）+ 约 0.8 GB/线程
#     6 线程 / 7 GB 机器  -> peak >7 GB，OOM 被杀
#     2 线程 / 7 GB 机器  -> RSS 6.19 GB，机器被拖到 SSH/NFS 全断
# 综合（Genus 4 线程 69k 单元）只需 1.5 GB，与布线不是一个量级。
MEM_GB=$(awk '/^MemTotal:/{printf "%d", $2/1048576}' /proc/meminfo)
if   [ "$MEM_GB" -ge 14 ]; then PNR_CPUS=6
elif [ "$MEM_GB" -ge 10 ]; then PNR_CPUS=4
elif [ "$MEM_GB" -ge 8  ]; then PNR_CPUS=3
else                            PNR_CPUS=2
fi
export PNR_CPUS
echo "[pnr] MemTotal=${MEM_GB} GB -> 布线线程数 PNR_CPUS=$PNR_CPUS"

# ---- 内存护栏：超过上限就主动收手，别让 VM 被 OOM 打挂 ----------------
# 打挂的代价是整台 VM 失去响应（需要人工重启 + 重启 NAT 服务），
# 而主动终止只是丢一次布线结果（CTS checkpoint 还在，可再来）。
MEM_WARN_GB=${MEM_WARN_GB:-12}
MEM_KILL_GB=${MEM_KILL_GB:-14}
(
  while pgrep -x innovus >/dev/null 2>&1; do
    rss_kb=$(ps -eo rss,comm | awk '$2=="innovus"{s+=$1} END{printf "%d", s}')
    rss_gb=$(( ${rss_kb:-0} / 1048576 ))
    if [ "$rss_gb" -ge "$MEM_KILL_GB" ]; then
      echo "[pnr] ⚠ innovus RSS ${rss_gb} GB >= ${MEM_KILL_GB} GB，主动终止以免 VM 被 OOM 拖死" >&2
      pkill -TERM -x innovus
      break
    elif [ "$rss_gb" -ge "$MEM_WARN_GB" ]; then
      echo "[pnr] ⚠ innovus RSS ${rss_gb} GB（警戒线 ${MEM_WARN_GB} GB）"
    fi
    sleep 20
  done
) &
WATCHDOG=$!
trap 'kill $WATCHDOG 2>/dev/null' EXIT


# SDC 清洗：Genus 导出的 sdc 里有 set_dont_use [get_lib_cells <lib>/FRICG_*]，
# <lib> 是 .lib 的内部库名，Innovus 在 source sdc 时报 TCLCMD-917 并中断流程。
# 这些行只约束时钟门控单元，本设计没有 ICG（综合时该属性不被 15.2 支持），
# 因此剔除它们不影响时序，剔除后原文件保留不动以便追溯。
CLEAN_SDC="$PNR_OUT/netlist_clean.sdc"
removed=$(grep -c "get_lib_cells" "$PNR_SDC" || true)
grep -v "get_lib_cells" "$PNR_SDC" > "$CLEAN_SDC"
echo "[pnr] SDC 清洗：剔除 $removed 行库单元引用 -> $CLEAN_SDC"
export PNR_SDC="$CLEAN_SDC"

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
