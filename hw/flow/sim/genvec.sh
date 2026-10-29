#!/usr/bin/env bash
# =====================================================================
#  flow/sim/genvec.sh —— 用黄金模型导出 RTL 测试向量
#
#  用法： bash flow/sim/genvec.sh <seed> [smoke|full] [check]
#
#  为什么向量由 C 模型生成、而不是另写一个 Python 脚本：
#    "逐位一致的软件模型"和"测试向量"必须出自同一份代码。
#    只要多一条重新实现的路径，就多一个不一致的来源，而那正是要被扣分的地方。
#
#  数值格式从 config/variants.mk 经 Makefile 传进来（QB/QF/LUT/CFGTAG），
#  这里不给默认值：脚本里再写一份默认值，就等于给"格式漂移"留了后门。
#
#  产出： tb/vectors/s<seed>/      （smoke 集进版本库，full 集不进）
#         qkv / ref 与格式无关，全方案共享；
#         exp 带格式标签：_exp_qb<qb>qf<qf>.hex
#         清单也按格式分：manifest_qb<qb>qf<qf>.txt / geninfo_qb<qb>qf<qf>.txt
#  环境： QB QF LUT CFGTAG MODE  由 hw/Makefile export
# =====================================================================
set -uo pipefail

SEED=${1:?用法: genvec.sh <seed> [smoke|full] [check]}
MODE=${2:-smoke}
CHECK=${3:-}
# smoke 集小（约 110 KB），进版本库让别人不经模型也能快速复跑；
# full 集大（约 6 MB），按需生成、不进库 —— 但 seed 进库，永远可重算。
SUF=""
[ "$MODE" = "full" ] && SUF="_full"
OUT="tb/vectors/s$SEED$SUF"

# 格式必须来自 variants.mk。缺了就报错，绝不猜一个默认值。
: "${QB:?未设置 QB —— 请用 make vec 调用（值来自 config/variants.mk）}"
: "${QF:?未设置 QF —— 请用 make vec 调用}"
: "${LUT:?未设置 LUT —— 请用 make vec 调用}"
TAG="qb${QB}qf${QF}"

echo "[vec] 编译数值模型"
make -s -C model vecbin || { echo "✗ 模型编译失败"; exit 1; }

if [ "$CHECK" = "check" ]; then
    [ -d "$OUT" ] || { echo "✗ 向量目录不存在: $OUT"; exit 1; }
    model/attn_dumpvec --check "$SEED" "$OUT" "$MODE" "$QB" "$QF" "$LUT"
    exit $?
fi

mkdir -p "$OUT"

# 旧版脚本写的是不带标签的 _exp.hex / manifest.txt / geninfo.txt。
# 留着它们会让 tb 悄悄读到过期黄金值，或让人以为清单是最新的，
# 所以一旦发现就删掉（只删这三种，不动别的文件）。
STALE_EXP=$(ls "$OUT"/*_exp.hex 2>/dev/null | wc -l)
if [ "$STALE_EXP" -gt 0 ]; then
    echo "[vec] 清理 $STALE_EXP 个旧版无标签 _exp.hex（已改为 _exp_$TAG.hex）"
    rm -f "$OUT"/*_exp.hex
fi
if [ -f "$OUT/manifest.txt" ] || [ -f "$OUT/geninfo.txt" ]; then
    echo "[vec] 清理旧版无标签 manifest.txt / geninfo.txt（已改为 *_$TAG.txt）"
    rm -f "$OUT/manifest.txt" "$OUT/geninfo.txt"
fi

echo "[vec] 导出 seed=$SEED mode=$MODE cfg=$TAG (qb=$QB qf=$QF lut=$LUT)"
model/attn_dumpvec "$SEED" "$OUT" "$MODE" "$QB" "$QF" "$LUT" || exit 1

# 生成环境单独记一个文件：manifest_<cfg>.txt 只放确定性的内容，
# 这样同一 seed 重跑在 git 里是零 diff，而"谁在哪台机器上生成的"也查得到。
# 同样按格式分文件 —— 它记录的就是"这个格式是在哪生成的"。
{
    echo "generated = $(date -Iseconds)"
    echo "host      = $(hostname)"
    echo "gcc       = $(gcc --version 2>/dev/null | head -1)"
    echo "mode      = $MODE"
    echo "cfg       = $TAG"
} > "$OUT/geninfo_$TAG.txt"

# 生成完立刻回读校验一遍：抓"写了但没写全"这类不会报错的失败
model/attn_dumpvec --check "$SEED" "$OUT" "$MODE" "$QB" "$QF" "$LUT" || {
    echo "✗ 刚生成的向量回读校验不通过 —— 磁盘或文件系统有问题"
    exit 1
}

echo "[vec] → $OUT  ($(ls "$OUT" | wc -l) 个文件)"
