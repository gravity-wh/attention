#!/usr/bin/env bash
# =====================================================================
#  flow/sim/unit.sh —— 编译并运行四个单元 tb（fp16_quant / exp2 / fix2fp16 / recip）
#
#  用法： bash flow/sim/unit.sh <variant> <tag>
#         ONLY=exp2 bash flow/sim/unit.sh ref unit-ref     # 只跑一个
#
#  前件：QB / QF / LUT 由 make 从 config/variants.mk 传下来（与系统级仿真同源）
#  产出： runs/<tag>/unit_<name>.log        每个单元的完整日志
#         runs/<tag>/unit/<...>/build_*.log 编译日志
#
#  退出码：0 = 四个全 PASS，1 = 有失败（make 会因此停下）
#
#  ── 为什么单元 tb 单独一条链，不塞进 build.sh ────────────────────────
#  build.sh 编的是"一个方案的顶层 + 系统级 tb"，一个 simv 跑六类激励；
#  单元 tb 各自只有一个模块，四个 tb 互不相干，共用一个 simv 反而要复用
#  顶层（VCS 多顶层会并发跑，结果混在一起）。分开编，日志也分开，定位更直接。
# =====================================================================
set -uo pipefail

VARIANT=${1:-ref}
TAG=${2:-unit-$VARIANT}
ONLY=${ONLY:-all}

: "${QB:?未设置 QB —— 请用 make unit 调用}"
: "${QF:?未设置 QF —— 请用 make unit 调用}"
: "${LUT:?未设置 LUT —— 请用 make unit 调用}"

OUT="runs/$TAG"
BINDIR="$OUT/unit"
mkdir -p "$OUT" "$BINDIR"

INC="+incdir+rtl/common +incdir+rtl/core"
DEFS="+define+ATTN_QB=$QB +define+ATTN_QF=$QF +define+ATTN_LUT=$LUT"

# 名字 → 被测源文件（顺序必须与 tb 文件名对齐）
NAMES="fp16_quant exp2 fix2fp16 recip"

echo "[unit] variant=$VARIANT cfg=qb${QB}qf${QF}/lut${LUT} → $OUT"

pass=0
fail=0
declare -a ROW

for n in $NAMES; do
    [ "$ONLY" != "all" ] && [ "$ONLY" != "$n" ] && continue

    case "$n" in
        fp16_quant) SRC="rtl/core/fp16_quant.sv"  TB="tb/unit/tb_unit_fp16_quant.sv" ;;
        exp2)       SRC="rtl/core/exp2_unit.sv"   TB="tb/unit/tb_unit_exp2.sv"       ;;
        fix2fp16)   SRC="rtl/core/fix2fp16.sv"    TB="tb/unit/tb_unit_fix2fp16.sv"   ;;
        recip)      SRC="rtl/core/recip_unit.sv"  TB="tb/unit/tb_unit_recip.sv"      ;;
        *) continue ;;
    esac

    echo "[unit] ---- $n ----"
    # 注意 attn_math.svh 是**作为设计文件**进来的，不是靠模块里的 include：
    # 实测 VCS 把这一批文件放在同一个编译单元里，`ifndef ATTN_MATH_SVH 守卫
    # 会跨文件生效 —— 谁先 include 谁独占（模块内局部），后面所有文件的
    # include 全部被跳过，表现就是 Identifier not declared。
    # 把 .svh 直接列成设计文件，函数就落在 $unit 作用域，谁都能用。
    # 主流程的 rtl/*/filelist.f 也是这个做法（漏了就会踩同一个坑）。
    if ! vcs -full64 -sverilog -timescale=1ns/1ps \
            -debug_access+all -kdb -line \
            $DEFS $INC \
            rtl/common/attn_pkg.sv \
            rtl/core/attn_math.svh \
            tb/unit/unit_ref_pkg.sv \
            "$SRC" "$TB" \
            -Mdir="$BINDIR/csrc_$n" \
            -o "$BINDIR/simv_$n" \
            >> "$BINDIR/build_$n.log" 2>&1; then
        echo "[unit] ✗ $n 编译失败，见 $BINDIR/build_$n.log"
        # 只打 Error 行容易看不出上下文（VCS 的 IND 错误要下一行才给出名字）
        grep -A4 -iE "Error-\[|error:" "$BINDIR/build_$n.log" | head -20
        fail=$((fail + 1))
        ROW+=("$n|-|编译失败|-")
        continue
    fi

    LOG="$OUT/unit_$n.log"
    "$BINDIR/simv_$n" -l "$LOG" > /dev/null 2>&1

    if grep -q '^\[FATAL\]' "$LOG" 2>/dev/null; then
        grep -m3 '^\[FATAL\]' "$LOG"
        echo "[unit] ✗ $n 在准备阶段就退出"
        fail=$((fail + 1))
        ROW+=("$n|-|FATAL|-")
        continue
    fi

    SUMMARY=$(grep -m1 '^\[UNIT\] name=' "$LOG" | tail -1)
    STATUS=$(sed -n 's/^\[SUMMARY\].*status=\([A-Z]*\).*/\1/p' "$LOG" | tail -1)
    [ -z "$STATUS" ] && STATUS="NO-SUMMARY"

    echo "$SUMMARY"

    if [ "$STATUS" = "PASS" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        # 失败时必须把前几条失配打到这里：单元 tb 的失配信息是定位的全部依据，
        # 埋在日志里等于要人再进一次虚拟机。
        grep -E '✗' "$LOG" | head -12
    fi

    # 从汇总行里抽出"检查了多少点"和"失配多少点"，供最后的表用
    # 注意用 grep -oE 而不是 sed BRE 的分支：`\(a\|b\)` 在 BSD/GNU 的 BRE 下
    # 行为不一致，实测直接把整列抽成空字符串。
    CHECKED=$(echo "$SUMMARY" | grep -oE '(checked|legal)=[0-9]+' | head -1 | cut -d= -f2)
    NFAIL=$(echo "$SUMMARY" | grep -oE '(^| )fail=[0-9]+' | head -1 | tr -d ' ' | cut -d= -f2)
    ROW+=("$n|${CHECKED:--}|$STATUS|${NFAIL:--}")
done

echo "[unit] ================= 汇总 ================="
printf "[unit] %-12s %-10s %-6s %s\n" "unit" "points" "status" "fail"
for r in "${ROW[@]:-}"; do
    IFS='|' read -r a b c d <<< "$r"
    printf "[unit] %-12s %-10s %-6s %s\n" "$a" "$b" "$c" "$d"
done

if [ "$fail" -ne 0 ]; then
    echo "[unit] ✗ $fail 个单元未通过（通过 $pass 个）"
    exit 1
fi
echo "[unit] ✓ $pass 个单元全部通过"
exit 0
