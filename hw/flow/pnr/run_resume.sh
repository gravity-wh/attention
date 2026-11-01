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



# ---- 按实际内存选线程数（实测标定，非拍脑袋）-------------------------
# 实测（69k 单元，信号层 M2-M5）：
#   布线内存 ≈ 5 GB 基线（设计规模决定）+ 约 0.8 GB/线程
#     6 线程 / 7 GB 机器  -> peak >7 GB，OOM 被杀
#     2 线程 / 7 GB 机器  -> RSS 6.19 GB，机器被拖到 SSH/NFS 全断
# 综合（Genus 4 线程 69k 单元）只需 1.5 GB，与布线不是一个量级。
MEM_GB=$(awk '/^MemTotal:/{printf "%d", $2/1048576}' /proc/meminfo)
if   [ "$MEM_GB" -ge 14 ]; then _AUTO=6
elif [ "$MEM_GB" -ge 10 ]; then _AUTO=4
elif [ "$MEM_GB" -ge 8  ]; then _AUTO=3
else                            _AUTO=2
fi
# 允许外部显式覆盖（回退阶梯靠它降级）：PNR_CPUS=4 make pnr-resume ...
PNR_CPUS=${PNR_CPUS:-$_AUTO}
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

echo "[pnr] 续跑：$PNR_OUT（$PNR_CPUS 线程）"
cd "$(dirname "$0")/../.." || die "进不去 hw/ 目录"

timeout 21600 innovus -no_gui -files flow/pnr/resume_route.tcl 2>&1 | tee "$PNR_OUT/resume.log"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || die "innovus 退出码 $rc（见 $PNR_OUT/resume.log）"
grep -q "\[pnr\] ========== DONE ==========" "$PNR_OUT/resume.log" \
    || die "续跑没到 DONE（见 $PNR_OUT/resume.log 末尾）"

echo "[pnr] ✓ 续跑完成：$PNR_OUT"
