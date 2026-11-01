#!/usr/bin/env bash
# =====================================================================
#  flow/pnr/run_resume.sh —— 从 after_cts.enc 续跑布线
#
#  背景：pnr.tcl 在 6 线程下跑 detail routing 会被 OOM 杀掉（退出码 137）。
#  CTS 后已存盘，这里用 2 线程续跑，避免重做 40 分钟的 place + CTS。
#
#  用法： make pnr-resume VARIANT=ref TAG=ref-sm40-tt PDK=SC9MC
# =====================================================================
set -uo pipefail

die() { echo "✗ $*" >&2; exit 1; }

[ -n "${PNR_OUT:-}" ] || die "缺 PNR_OUT —— 请用 make pnr-resume 调用"
[ -n "${PNR_TOP:-}" ] || die "缺 PNR_TOP"

command -v innovus >/dev/null || die "找不到 innovus"
[ -e "$PNR_OUT/after_cts.enc.dat" ] || die "缺 CTS checkpoint: $PNR_OUT/after_cts.enc.dat
    先跑 make pnr VARIANT=.. TAG=.. （CTS 完成时会自动存盘）"

if pgrep -x innovus >/dev/null 2>&1; then
    echo "✗ 已有 innovus 在跑：" >&2; pgrep -a -x innovus >&2
    die "先等它结束或 pkill -9 -x innovus"
fi


# ---- 按实际内存选线程数 -------------------------------------------------
# 实测（7 GB VM，69k 单元，信号层 M2-M5）：
#   6 线程 -> peak > 7 GB，被 OOM killer 杀（退出码 137）
#   2 线程 -> RSS 6.2 GB，仍把机器拖到无响应
# 经验值：布线峰值 ≈ 1.5–2.5 GB/线程 + 2 GB 基础开销。
# 12 GB 给 4 线程、16 GB 给 6 线程、其余按 1 线程/2.5 GB 保守估。
MEM_GB=$(awk '/^MemTotal:/{printf "%d", $2/1048576}' /proc/meminfo)
if   [ "$MEM_GB" -ge 15 ]; then PNR_CPUS=6
elif [ "$MEM_GB" -ge 11 ]; then PNR_CPUS=4
elif [ "$MEM_GB" -ge 9  ]; then PNR_CPUS=3
else                            PNR_CPUS=2
fi
export PNR_CPUS
echo "[pnr] MemTotal=${MEM_GB} GB -> 布线线程数 PNR_CPUS=$PNR_CPUS"

echo "[pnr] 续跑：$PNR_OUT（$PNR_CPUS 线程）"
cd "$(dirname "$0")/../.." || die "进不去 hw/ 目录"

timeout 21600 innovus -no_gui -files flow/pnr/resume_route.tcl 2>&1 | tee "$PNR_OUT/resume.log"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || die "innovus 退出码 $rc（见 $PNR_OUT/resume.log）"
grep -q "\[pnr\] ========== DONE ==========" "$PNR_OUT/resume.log" \
    || die "续跑没到 DONE（见 $PNR_OUT/resume.log 末尾）"

echo "[pnr] ✓ 续跑完成：$PNR_OUT"
