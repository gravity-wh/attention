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
[ -f "$PNR_OUT/after_cts.enc.dat" ] || die "缺 CTS checkpoint: $PNR_OUT/after_cts.enc.dat
    先跑 make pnr VARIANT=.. TAG=.. （CTS 完成时会自动存盘）"

if pgrep -x innovus >/dev/null 2>&1; then
    echo "✗ 已有 innovus 在跑：" >&2; pgrep -a -x innovus >&2
    die "先等它结束或 pkill -9 -x innovus"
fi

echo "[pnr] 续跑：$PNR_OUT（2 线程，内存敏感）"
cd "$(dirname "$0")/../.." || die "进不去 hw/ 目录"

timeout 21600 innovus -no_gui -files flow/pnr/resume_route.tcl 2>&1 | tee "$PNR_OUT/resume.log"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || die "innovus 退出码 $rc（见 $PNR_OUT/resume.log）"
grep -q "\[pnr\] ========== DONE ==========" "$PNR_OUT/resume.log" \
    || die "续跑没到 DONE（见 $PNR_OUT/resume.log 末尾）"

echo "[pnr] ✓ 续跑完成：$PNR_OUT"
