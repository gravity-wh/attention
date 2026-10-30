#!/usr/bin/env bash
# =====================================================================
#  flow/synth/run_syn.sh —— 一次综合的完整包装
#
#  用法（只由 make syn 调用）：
#      run_syn.sh <variant> <run_dir> <clock_mhz> <pvt_tag>
#
#  它负责四件事，缺一件结果就不可信：
#    1. 预检 —— 工具、库、LEF、约束参数齐全才开跑（宁可不动，不要跑出个假数）
#    2. 生成 SDC 与清洗后的 filelist（filelist 里的 // 注释和 .svh 会让
#       Genus 的 -f 解析出问题；仿真器能吃，不代表综合器能吃）
#    3. 调 Genus，日志落 runs/<TAG>/syn/syn.log
#    4. 解析指标 + **校验面积非零**。库是演示库，面积只能来自 LEF；
#       LEF 没读到就会静默报 0，0 面积混进报告表等于造假。
#
#  产出（都在 runs/<TAG>/syn/ 下）：
#    constraints.sdc  filelist.clean.f  syn.log  area.rpt  timing.rpt
#    power.rpt  qor.rpt  netlist.v  netlist.sdc  metrics.tcl  metrics.csv
# =====================================================================
set -uo pipefail

VARIANT=${1:?用法: run_syn.sh <variant> <run_dir> <clock_mhz> <pvt>}
RUN=${2:?}
CLK_MHZ=${3:?}
PVT_TAG=${4:-unknown}
OUT="$RUN/syn"

die() { echo "✗ $*" >&2; exit 1; }

# ------------------------------------------------------------------ 1. 预检
command -v genus >/dev/null || die "找不到 genus（综合在 VM 上跑：用 runvm.sh）"
[ -n "${SYN_LIB:-}" ] || die "SYN_LIB 未设置 —— 检查 config/pdk.mk 的 include"
[ -n "${SYN_LEF:-}" ] || die "SYN_LEF 未设置 —— 检查 config/pdk.mk 的 include"
[ -f "$SYN_LIB" ] || die "时序库不存在: $SYN_LIB
     VM 上的路径才对；在 Windows 侧跑必然找不到。用 runvm.sh 执行。"
[ -f "$SYN_LEF" ] || die "LEF 不存在: $SYN_LEF（没有 LEF 就拿不到单元面积）"
[ -n "${TOP:-}" ] || die "TOP 未设置"
[ -f "${FLIST:?}" ] || die "filelist 不存在: $FLIST"
case "$CLK_MHZ" in ''|*[!0-9.]*) die "CLOCK 不是数字: $CLK_MHZ";; esac

for v in QB QF LUT SYN_DRIVE_CELL SYN_LOAD_PF SYN_CLK_UNCERT_PCT \
         SYN_IO_DELAY_PCT SYN_TOGGLE_RATE SYN_STATIC_PROB; do
    [ -n "${!v:-}" ] || die "$v 未设置 —— 综合约束必须显式声明，不许用脚本内默认值"
done

# 孤儿进程检查：runvm 那类"宿主机断了、客户机还在跑"的场景会留下
# 上轮的 genus。它会一直占着 CPU 和 license，本轮要么排队要么抢不到，
# 表现为"综合莫名其妙跑了十几分钟还没结果"。宁可在这里直接停下。
if pgrep -x genus >/dev/null 2>&1; then
    echo "✗ 已经有 genus 在跑：" >&2
    ps -eo pid,etime,args | awk '/genus/ && !/awk/ {printf "    %s\n", $0}' >&2
    die "先 pkill -9 -x genus 再重跑。两个 genus 并行会互相抢 license 与 CPU，
     而且本轮会踩在上轮被删掉的工作目录上，报出与真 bug 无关的错。"
fi

mkdir -p "$OUT"

# ------------------------------------------------------------------ 2. 派生数值
# 用 python3 算，避免 awk 的浮点格式在不同机器上给出不同位数。
read -r CLK_NS IODLY_NS UNC_NS < <(python3 - "$CLK_MHZ" \
        "$SYN_IO_DELAY_PCT" "$SYN_CLK_UNCERT_PCT" <<'PY'
import sys
mhz, io_pct, unc_pct = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
if mhz <= 0:
    sys.exit("CLOCK 必须 > 0")
p = 1000.0 / mhz
print("%.4f %.4f %.4f" % (p, p * io_pct / 100.0, p * unc_pct / 100.0))
PY
) || die "约束参数换算失败"

# ------------------------------------------------------------------ 3. 清洗 filelist
# 只去行内注释与空行，**不筛掉 .svh**。
#   attn_math.svh 是故意以「设计文件」身份列进 filelist 的：它带
#   `ifndef ATTN_MATH_SVH 守卫，所以必须整体编译一次（$unit 作用域），
#   各模块里的 `include 才会被守卫挡掉、改去引用这一份。
#   早期版本这里加过 `grep -v '\.svh$'` 想"只留源文件"，结果把这一行也
#   删了 —— 表现是 Genus 报几十条 "Unresolved subprogram reference"，
#   而仿真一直是好的（VCS 读到的是原始 filelist）。
#   仿真与综合必须吃同一份清单，任何"顺手清理"都要先想清楚它在喂谁。
#
# 三个数值格式宏用 +define+ 写在 filelist 里，而不是 read_hdl -define：
# Genus 不允许 -define 与 -f 同时出现（报 HDL-12），且它自己就建议改用
# list 文件里的 +define+。宏必须与仿真完全一致，否则 attn_pkg 的
# Q_BITS/Q_FRAC 会退回默认值，综合的电路与验证过的不是同一个。
{
    echo "+define+ATTN_QB=$QB"
    echo "+define+ATTN_QF=$QF"
    echo "+define+ATTN_LUT=$LUT"
    sed -e 's|//.*||' -e 's|[[:space:]]*$||' "$FLIST" | awk 'NF'
} > "$OUT/filelist.clean.f"
[ -s "$OUT/filelist.clean.f" ] || die "清洗后的 filelist 为空"
echo "[syn] filelist: $(grep -c . "$OUT/filelist.clean.f") 行（含 +incdir+）"

# ------------------------------------------------------------------ 4. SDC
cat > "$OUT/constraints.sdc" <<EOF
# 由 run_syn.sh 生成，勿手改（改了下次 make syn 就被覆盖）
# 目标频率 ${CLK_MHZ} MHz → 周期 ${CLK_NS} ns
# 输入/输出延迟各 ${SYN_IO_DELAY_PCT}% 周期，时钟不确定性 ${SYN_CLK_UNCERT_PCT}% 周期
# 驱动单元 ${SYN_DRIVE_CELL}，输出负载 ${SYN_LOAD_PF} pF
create_clock -name clk -period ${CLK_NS} [get_ports clk]
set_clock_uncertainty ${UNC_NS} [get_clocks clk]

# 输入侧：外面有一级寄存器 + ${SYN_IO_DELAY_PCT}% 周期的路径延迟。
# 时钟端口本身不设驱动单元（它由时钟树驱动，不是数据）。
set_driving_cell -lib_cell ${SYN_DRIVE_CELL} -pin Y \
    [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay ${IODLY_NS} -clock clk \
    [remove_from_collection [all_inputs] [get_ports clk]]
set_input_transition 0.05 [all_inputs]

set_load ${SYN_LOAD_PF} [all_outputs]
set_output_delay ${IODLY_NS} -clock clk [all_outputs]

# rst_n 是异步复位，不做时序检查（否则会被当成一条跨时钟路径）
set_false_path -from [get_ports rst_n]
EOF

# ------------------------------------------------------------------ 5. 跑 Genus
echo "[syn] $VARIANT  目标 ${CLK_MHZ} MHz  角 $PVT_TAG  库 $(basename "$SYN_LIB")"
# 事前事后各打一次目录清单：曾经出现过"genus 明明读过 filelist、最后却说
# constraints.sdc 打不开"的情况，而事后目录整个不见了。没有这两行就只能猜。
echo "[syn] 事前 $OUT 内容:"; ls -la "$OUT" | sed 's/^/    /'

# syn.tcl 里按 *_NS 的名字读约束（它不该自己再换算一遍），所以这里要补上。
# 数值格式同理：Makefile 导出的是 QB/QF/LUT，Tcl 侧统一叫 SYN_QB/QF/LUT，
# 名字对不上时 tcl 会报 "can't read env(...)" 然后掉进交互模式——
# 表现是"综合卡住不返回"，比报错更难查，所以这里一次都对齐。
export SYN_TOP="$TOP" SYN_FLIST="$PWD/$OUT/filelist.clean.f" SYN_OUT="$PWD/$OUT" \
       SYN_CLK_NS="$CLK_NS" SYN_IODLY_NS="$IODLY_NS" SYN_UNC_NS="$UNC_NS" \
       SYN_IO_DELAY_NS="$IODLY_NS" SYN_CLK_UNCERT_NS="$UNC_NS" \
       SYN_QB="$QB" SYN_QF="$QF" SYN_LUT="$LUT"
( cd "$PWD" && genus -no_gui -files flow/synth/syn.tcl ) 2>&1 | tee "$OUT/syn.log"
GEN_RC=${PIPESTATUS[0]}

echo "[syn] 事后 $OUT 内容:"; ls -la "$OUT" 2>&1 | sed 's/^/    /'

[ "$GEN_RC" -eq 0 ] || die "genus 退出码 $GEN_RC（见 $OUT/syn.log）"
grep -q "\[syn\] DONE" "$OUT/syn.log" || die "genus 未跑到结束（见 $OUT/syn.log 末尾）"

# ------------------------------------------------------------------ 6. 解析指标
# PYTHONIOENCODING：客户机 locale 是 C，Python3 的 stdout 会按 ASCII 编码，
# 脚本里任何一句中文 print 都会抛 UnicodeEncodeError 并盖掉真正的错误。
export PYTHONIOENCODING=utf-8
python3 flow/synth/parse_syn.py "$OUT" "$CLK_MHZ" "$PVT_TAG" "$VARIANT" "$TOP" \
  || die "指标解析失败（见 $OUT/syn.log）"

# ------------------------------------------------------------------ 7. 体检
# 面积必须非零。库的 .lib 里 area 全是 0，唯一来源是 LEF；
# 这一项为 0 说明 read_physical 没生效，此时任何"面积改善"都是假的。
AREA=$(awk -F, '$1=="area_um2"{print $2}' "$OUT/metrics.csv")
awk -v a="$AREA" 'BEGIN{exit !(a+0 > 0)}' \
  || die "总面积 = ${AREA:-0} µm² —— read_physical -lef 没生效。
     库的 .lib 里单元 area 全为 0.0，面积只能来自 LEF。
     检查 $SYN_LEF 是否存在、Genus 是否支持该 LEF 版本。"

echo "[syn] ✓ 完成：$(cat "$OUT/metrics.csv")"
