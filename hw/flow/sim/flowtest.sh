#!/usr/bin/env bash
# =====================================================================
#  flow/sim/flowtest.sh —— 验证「流程本身」可用（不需要真实 RTL）
#
#  两个必过的自检：
#    A. 判据自检  +SELFTEST=1：把期望值直接当输出，判据必须判 PASS
#       → 证明 RMSE/逐位比对的实现是对的，不是永远 FAIL 或永远 PASS
#    B. 夹具自检  用 top_stub（输出全 0）跑一个任务，必须判 FAIL
#       → 证明驱动、装数、握手、比对、退出码这条链路真的在工作
#
#  任何一个不成立，说明 tb 或流程有 bug，此时去写 RTL 是白写。
# =====================================================================
set -uo pipefail

SEED=${1:-20260101}
TAG="_flowtest"
RUN="runs/$TAG"
OUT="tb/vectors/s$SEED"

# 数值格式必须由调用方给出（make flowtest 从 config/variants.mk 传下来）。
# 这里曾经写 ${QB:-16} / ${CFGTAG:-qb16qf13} 兜底，等于在"格式唯一真源"
# 之外又留了一份默认值：万一调用方漏传，flowtest 会拿 16/13 的黄金值去
# 校验 10/7 的 DUT，然后报一个看着像 RTL bug 的失配 —— 这类失配最费时间。
: "${QB:?未设置 QB —— 请用 make flowtest 调用（值来自 config/variants.mk）}"
: "${QF:?未设置 QF —— 请用 make flowtest 调用}"
: "${LUT:?未设置 LUT —— 请用 make flowtest 调用}"
: "${CFGTAG:?未设置 CFGTAG —— 请用 make flowtest 调用}"

mkdir -p "$RUN"

if [ ! -d "$OUT" ]; then
    echo "[flowtest] 先生成 smoke 向量"
    bash flow/sim/genvec.sh "$SEED" smoke || exit 1
fi

echo "================================================================"
echo " 编译 tb + stub（不依赖任何方案实现）"
echo "================================================================"
vcs -full64 -sverilog -timescale=1ns/1ps \
    -debug_access+all -line \
    -pvalue+tb_attn.CLK_MHZ=100 \
    +define+DUT=top_stub \
    "+define+DUT_NAME=\"top_stub\"" \
    +define+ATTN_QB="$QB" \
    +define+ATTN_QF="$QF" \
    +define+ATTN_LUT="$LUT" \
    +incdir+rtl/common \
    rtl/common/attn_pkg.sv \
    tb/common/attn_tb_pkg.sv \
    tb/sys/tb_attn.sv \
    tb/stub/top_stub.sv \
    -Mdir="$RUN/csrc" -o "$RUN/simv" -l "$RUN/build.log"
if [ ! -x "$RUN/simv" ]; then
    echo "✗ 编译失败，见 $RUN/build.log"
    tail -25 "$RUN/build.log"
    exit 1
fi
echo "[flowtest] ✓ 编译通过"

echo
echo "================================================================"
echo " A. 判据自检（预期 PASS）"
echo "================================================================"
"$RUN/simv" +VECDIR="$OUT" +CFG="$CFGTAG" +CAT=random +N=1 +SELFTEST=1 -l "$RUN/selftest.log" > /dev/null 2>&1
grep -E "^\[SELFTEST\]" "$RUN/selftest.log" || tail -5 "$RUN/selftest.log"
# 判 PASS/FAIL 一律解析日志，不看 simv 退出码：
# VCS 的 $finish 永远返回 0，$fatal 又会卡约 90 秒才退出，退出码不可依赖。
if ! grep -q "^\[SELFTEST\] 判据自检 → PASS" "$RUN/selftest.log"; then
    echo "✗ A 未过：判据实现有问题（把期望值当输出都过不了）"
    exit 1
fi
echo "[flowtest] ✓ A 通过：判据能对正确数据判 PASS"

echo
echo "================================================================"
echo " B. 夹具自检（stub 输出全 0，预期 FAIL 且退出码 1）"
echo "================================================================"
"$RUN/simv" +VECDIR="$OUT" +CFG="$CFGTAG" +CAT=random +N=1 -l "$RUN/stub.log" > /dev/null 2>&1
grep -m2 -E "^\[task|结果：" "$RUN/stub.log" || true

# 判据以 [SUMMARY] 的 status 字段为准，不以 simv 的退出码为准：
# 不同仿真器对 $fatal 的退出码处理不一致，而 run.sh 也是解析这一行。
STATUS_B=$(grep -m1 -o 'status=[A-Z]*' "$RUN/stub.log" | cut -d= -f2)
if [ "$STATUS_B" != "FAIL" ]; then
    echo "✗ B 未过：stub 输出全 0 却判成 '$STATUS_B'，判据形同虚设"
    exit 1
fi
echo "[flowtest] ✓ B 通过：错误数据被正确判 FAIL（status=$STATUS_B）"

echo
echo "================================================================"
echo " 流程可用：tb / 驱动 / 判据 / 退出码 全部验证过"
echo " 现在可以去写 rtl/<variant>/top_<variant>.sv 了"
echo "================================================================"
exit 0
