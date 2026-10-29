#!/usr/bin/env bash
# =====================================================================
#  flow/preflight.sh —— 提交前自检
#
#  用法（只由 make preflight 调用，环境变量由 Makefile 导出）：
#      make preflight
#
#  它回答一个问题：**仓库现在自相矛盾吗？**
#  不回答"代码写得好不好"——那是 review 的事，机器管不了。
#
#  ── 为什么第 1 项不看 git status ──────────────────────────────────
#  本仓库在 SMB 共享盘上，索引的 stat 缓存刷不掉，git status 会把一批
#  没改过的 *.hex 报成 ` M`。实测过：这些文件与 git hash-object、
#  git cat-file -p 三方比对完全相同。所以真实变更只认
#  `git diff --name-only HEAD`（内容级比较）。
# =====================================================================
set -uo pipefail

fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
sec()  { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------- 1 变更集
sec "1/6 真实变更集（只用 git diff，不用 git status）"
CHANGED=$(git diff --name-only HEAD 2>/dev/null || true)
NCH=$(printf '%s' "$CHANGED" | grep -c . || true)
if [ "$NCH" -gt 0 ]; then
    warn "$NCH 个文件未提交 —— 现在跑出的数据绑不到 commit"
    printf '%s\n' "$CHANGED" | sed 's/^/      /'
else
    ok "工作区干净"
fi

# ---------------------------------------------------------------- 2 格式同源
# 三处必须指向同一个 (QB,QF)：variants.mk 的声明、向量的文件名、RTL 的宏。
# 后两者由同一个 CFGTAG 派生，能查的是"对应的 exp 文件在不在"。
sec "2/6 数值格式三处同源"
for v in ${VARIANTS:-ref varA varB}; do
    cfg=$(make -s --no-print-directory cfgof VARIANT="$v" 2>/dev/null)
    d="tb/vectors/s${SEED:-20260101}"
    n=$(ls "$d"/*_exp_"$cfg".hex 2>/dev/null | wc -l)
    if [ "$n" -eq 0 ]; then
        bad "$(printf '%-5s %-9s' "$v" "$cfg") 没有对应的 exp 向量（先 make vec VARIANT=$v）"
    else
        ok "$(printf '%-5s %-9s' "$v" "$cfg") exp 向量 $n 个"
    fi
done

# ---------------------------------------------------------------- 3 派生物
sec "3/6 派生物是否被跟踪"
TRACKED_BAD=$(git ls-files 2>/dev/null \
    | grep -E '\.(exe|o|log|vcd|fsdb|vpd|shm|svf|ddc|db|gds|spef)$' || true)
if [ -n "$TRACKED_BAD" ]; then
    bad "这些派生物不该进库："
    printf '%s\n' "$TRACKED_BAD" | sed 's/^/      /'
else
    ok "无"
fi

# ---------------------------------------------------------------- 4 未跟踪
sec "4/6 未跟踪的可疑文件"
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null \
    | grep -E '\.(o|vcd|fsdb|log|pyc)$' || true)
if [ -n "$UNTRACKED" ]; then
    warn "未跟踪但像派生物（确认后再决定要不要提交）："
    printf '%s\n' "$UNTRACKED" | sed 's/^/      /'
else
    ok "无"
fi

# ---------------------------------------------------------------- 5 工艺库
sec "5/6 工艺库可达性"
if [ -f "${SYN_LIB:-/nonexistent}" ]; then
    ok "${SYN_LIB}"
else
    warn "库文件不可达（非 VM 环境正常；综合前先跑 make pdkcheck）"
fi
if [ -n "${PVT:-}" ]; then
    ok "角 ${CORNER:-?} / PVT ${PVT}"
else
    bad "PVT 为空 —— config/pdk.mk 里没有 pvt_${CORNER:-tt}_${PDK:-?}"
fi

# ---------------------------------------------------------------- 6 数值层
sec "6/6 数值层两道闸"
if make -s --no-print-directory modeltest >/tmp/preflight_modeltest.log 2>&1; then
    ok "模型自检 $(grep -oE '[0-9]+ passed, [0-9]+ failed' /tmp/preflight_modeltest.log | tail -1)"
else
    bad "模型自检失败（见 /tmp/preflight_modeltest.log）"
fi
if make -s --no-print-directory vecfsck >/tmp/preflight_vecfsck.log 2>&1; then
    ok "向量与模型一致"
else
    bad "向量与模型不一致（见 /tmp/preflight_vecfsck.log）"
fi

# ---------------------------------------------------------------- 判决
echo
if [ "$fail" -ne 0 ]; then
    printf '\033[31m✗ preflight 未通过\033[0m\n'
    exit 1
fi
printf '\033[32m✓ 结构性检查通过\033[0m\n'
echo "  回归是否够，看改的是哪一层："
echo "    改 rtl/core|common → make regress（三个方案）"
echo "    改 flow/synth|config/pdk.mk → make syn，再 make collect"
echo "    改 model → make vec + make err，两者一起提交"
