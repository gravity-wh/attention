# P4 实验复现

采用 SMIC 40LL SC9MC RVT r1p1。基线为仓库当前 ref，任务周期按首次装载至最后一个输出。脚本从 hw/ 运行，所有实验产物使用自己的 TAG。

## 准备独立工作树

从包含这份归档的仓库根目录执行。兼容补丁用于 Verilator 回归和 Genus 25 功耗解析。

~~~bash
archive="$(pwd)/hw/results/p4-sm40-20261120"
scratch="$(mktemp -d)"
git worktree add --detach "$scratch" 9cdb03cef13a7badc2fb8c88b0cba6bc96c4ab67
cd "$scratch"
git apply --directory=hw "$archive/reproduce/baseline-compatibility.patch"
mkdir -p hw/experiments/p4
cp -R "$archive/reproduce/." hw/experiments/p4/
cd hw
~~~

下文命令均在该副本的 hw/ 下执行。用于晚释放和折叠的对照副本也需要同样的兼容补丁和脚本。

## RTL 和表 3

~~~bash
bash experiments/p4/regress-verilator.sh varB varB-early-release
~~~

对照副本只替换为提交 3c381e0 的 varB 顶层，然后用相同脚本运行 varB-late-release。折叠候选在另一干净副本中应用 fold-l2e.patch，再独立生成向量。回归脚本以已有的系统 testbench 和向量生成器为基础。

~~~bash
patch -p1 < experiments/p4/fold-l2e.patch
bash experiments/p4/regress-verilator.sh varB varB-fold-l2e
~~~

## 综合与布线

用相同版本 Genus 在 TT、100 MHz 下映射 ref 和 varB。布局布线用同样的利用率、IO 放置规则、金属栈和后布线提取设置，SS 查 setup，FF 查 hold。

~~~bash
make pdkcheck PDK=SC9MC CORNER=tt
make syn VARIANT=ref TAG=ref-sm40-tt-p4 PDK=SC9MC CORNER=tt SYN_CPUS=4
make syn VARIANT=varA TAG=varA-sm40-tt-p4 PDK=SC9MC CORNER=tt SYN_CPUS=4
make syn VARIANT=varB TAG=varB-sm40-tt-p4 PDK=SC9MC CORNER=tt SYN_CPUS=4

patch -p1 < experiments/p4/innovus25.patch
mkdir -p work_techlef
python3 experiments/p4/derive-techlef.py \
    /opt/cadence/PDK/smic40/derived/smic40_tech.lef work_techlef/smic40_tech.lef
PNR_CPUS=2 make pnr VARIANT=varB TAG=varB-sm40-tt-p4 PDK=SC9MC CORNER=tt
PNR_CPUS=2 make pnr VARIANT=ref TAG=ref-sm40-tt-p4 PDK=SC9MC CORNER=tt
~~~

Genus 从 TT Liberty 取得面积和延时。晚释放与折叠候选沿用前一节的独立副本，以 `VARIANT=varB` 和独立 TAG 运行同一综合命令。派生脚本沿用 gen_techlef.sh 的矩形方法，从各层默认 VIARULE 生成显式过孔。两个设计共用生成后的 tech LEF。扫描触发器用作功能单元，布局不执行 DFT 扫描排序。

保留 CTS 检查点后，可以在同一 TAG 下用单线程恢复布线。恢复路径沿用完整流程的布线、提取和检查命令。

~~~bash
P4_RESUME_CTS=1 PNR_CPUS=1 make pnr VARIANT=varB TAG=varB-sm40-tt-p4 PDK=SC9MC CORNER=tt
P4_RESUME_CTS=1 PNR_CPUS=1 make pnr VARIANT=ref TAG=ref-sm40-tt-p4 PDK=SC9MC CORNER=tt
~~~

## 活动功耗和固定网表扫频

在 Linux 下用 Yosys 从综合采用的 TT Liberty 生成零延迟功能模型，再用 Verilator 编译映射网表。每次仿真检查全部 256 个输出的地址和值。反标范围从第一拍装载到最后一个输出。以下为 ref 的 100 MHz 示例。

~~~bash
make vec MODE=full SEED=20260101 VARIANT=ref
gate=runs/ref-sm40-tt-p4/activity
mkdir -p "$gate"
cp runs/ref-sm40-tt-p4/syn/{netlist.v,constraints.sdc} "$gate/"
liberty=/opt/cadence/PDK/smic40/sc9mc_base_rvt_c40/r1p1/lib/sc9mc_logic0040ll_base_rvt_c40_tt_typical_max_1p10v_25c.lib
bash experiments/p4/gate-vcd.sh top_ref 100 "$gate/netlist.v" "$liberty" \
    tb/vectors/s20260101_full qb16qf13 "$gate/mhz100" random_0 zero_0 extreme_0 cancel_0 &&
    printf 'PASS\n' > "$gate/mhz100/gate.status"

bash experiments/p4/run-power-sweep.sh ref 100 "$gate/mhz100" runs/p4-power/ref/mhz100
python3 experiments/p4/collect-power.py runs/p4-power runs/p4-power/summary.csv
~~~

将方案改为 varB 或 varA 时，使用它们的网表和 qb10qf7 黄金值。扫频对 ref 和 varB 复用各自的 100 MHz 映射网表，重设各频点的时钟周期、I/O 延迟和不确定性，并重放相同 random_0。每个频点先报布局前 setup WNS，再用门级 VCD 反标计算动态与泄漏功耗。报告中的能耗等于任务窗口平均总功率乘以时长。零延迟仿真未计入 SDF 毛刺活动，布局前计时未计入布线寄生。

对照版和折叠版仿真使用 `top_varB`，分别读取各自的黄金向量。反标命令可设置 `P4_POWER_TOP=top_varB` 后使用独立方案名。四个频点齐全后，可从同一汇总生成扫频图。

~~~bash
python3 experiments/p4/plot-sweep.py runs/p4-power/summary.csv \
    ../docs/report/slides/figures/p4-frequency-sweep.png
~~~

## 答辩稿

[最终 PDF](../slides/ic_slides_p4_final.pdf) 与 [Beamer 源稿](../slides/ic_slides_p4.tex) 已归档。重新编译时，将源稿和扫频图复制到独立工作树的 docs/report/slides/ 及其 figures/ 目录，沿用仓库原有的 SEU 模板。在 Windows 上可从该独立目录运行 `build.ps1 -Name ic_slides_p4`。[模板构建说明](../../../../docs/report/slides/README.md)
