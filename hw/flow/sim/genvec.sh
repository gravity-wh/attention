#!/usr/bin/env bash
# =====================================================================
#  flow/sim/genvec.sh —— 用黄金模型导出 RTL 测试向量
#
#  用法： bash flow/sim/genvec.sh <seed> [smoke|full]
#
#  为什么向量由 C 模型生成、而不是另写一个 Python 脚本：
#    "逐位一致的软件模型"和"测试向量"必须出自同一份代码。
#    只要多一条重新实现的路径，就多一个不一致的来源，而那正是要被扣分的地方。
#
#  产出： tb/vectors/s<seed>/      （smoke 集会进版本库，full 集不进）
# =====================================================================
set -uo pipefail

SEED=${1:?用法: genvec.sh <seed> [smoke|full]}
MODE=${2:-smoke}
# smoke 集小（约 110 KB），进版本库让别人不经模型也能快速复跑；
# full 集大（约 6 MB），按需生成、不进库 —— 但 seed 进库，永远可重算。
SUF=""
[ "$MODE" = "full" ] && SUF="_full"
OUT="tb/vectors/s$SEED$SUF"

echo "[vec] 编译数值模型"
make -s -C model vecbin || { echo "✗ 模型编译失败"; exit 1; }

mkdir -p "$OUT"

# 定点配置必须与 attn_pkg.sv 里的常量、以及 width_sweep 的结论一致
QB=${QB:-16}
QF=${QF:-13}
LUT=${LUT:-4}

echo "[vec] 导出 seed=$SEED mode=$MODE qb=$QB qf=$QF lut=$LUT"
model/attn_dumpvec "$SEED" "$OUT" "$MODE" "$QB" "$QF" "$LUT" || exit 1

# 记录生成时间与工具版本 —— 报告表 1 要填"测试集版本及随机种子"
{
    echo "generated = $(date -Iseconds)"
    echo "host      = $(hostname)"
    echo "gcc       = $(gcc --version 2>/dev/null | head -1)"
    echo "mode      = $MODE"
} >> "$OUT/manifest.txt"

echo "[vec] → $OUT"
ls "$OUT" | head -5
echo "[vec] 共 $(ls "$OUT" | wc -l) 个文件"
