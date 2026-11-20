# P4 实验记录

基线为仓库的 ref，优化方案为 varB。RTL 锚点为 9cdb03cef13a7badc2fb8c88b0cba6bc96c4ab67。测量使用 SMIC 40LL、SC9MC RVT r1p1，综合角 TT 1.10 V、25 °C，主时钟 100 MHz。历史 Genus 15.20 的三方案表 2 见 [11 月 14 日归档](../sm40-rerun-20261114)。新跑工具与条件按各表记录。

## RTL 复测

- 模拟器为 [Verilator 5.032](rtl/verilator-version.txt)，完整向量 seed 为 20260101。三次 varB 回归均为 616/616 通过、逐位失配 0，装载均实测为 768 拍。
- 表 3 调整前从 3c381e0 的 top_varB.sv 取顶层，其余 RTL、模型、向量、testbench 与调整后相同。归一化结束释放指数缓冲后，纯计算 1,738 → 1,423 拍，完整任务 2,506 → 2,191 拍，时延降低 12.6%。两版最大 RMSE 和绝对误差完全一致。
- 折叠候选在 K 装载时进行定点换底，并由配套的 C 模型产生该候选的逐位期望值。折叠前后的 float64 参考相同。最大 RMSE 从 0.002492 增至 0.003656，最大绝对误差从 0.006034 增至 0.008309，两者均在题面阈值内。最坏完整任务保持 2,191 拍。
- 同一次回归也复查了 [ref](rtl/ref-current.csv)、[varA](rtl/varA-current.csv) 和 [varB](rtl/varB-current.csv)。三方案各通过 616 项。

| 实验 | 原始汇总 | 复现输入 |
|---|---|---|
| varB 晚释放 | [前版 616 项](rtl/varB-late-release.csv) | [历史顶层](https://github.com/gravity-wh/attention/blob/3c381e0b03609e4c595188d43bb2b0b546da8152/hw/rtl/varB/top_varB.sv) |
| varB 早释放 | [现版 616 项](rtl/varB-early-release.csv) | 主分支 RTL |
| fold_l2e | [候选 616 项](rtl/varB-fold-l2e.csv) | [隔离试验补丁](../../experiments/p4/fold-l2e.patch) |

## TT 综合

Genus 25.12-s067_1 使用共同的综合约束。面积为映射后标准单元面积。功率报告使用 Genus 默认活动率，供综合过程对照。

| 方案 | 标准单元面积（µm²） | setup WNS（ns） | 单元数 | 触发器数 | 原始报告 |
|---|---:|---:|---:|---:|---|
| ref | 160,620.0 | +0.001 | 51,739 | 25,357 | [综合目录](synthesis/ref) |
| varA | 140,768.0 | 0.000 | 46,541 | 21,384 | [综合目录](synthesis/varA) |
| varB | 67,960.6 | 0.000 | 24,190 | 9,411 | [综合目录](synthesis/varB) |
| varB 晚释放 | 67,867.5 | 0.000 | 24,264 | 9,411 | [综合目录](synthesis/varB-late) |
| fold_l2e | 67,099.5 | 0.000 | 23,874 | 9,411 | [综合目录](synthesis/varB-fold) |

## 任务窗口功耗

使用 Verilator 5.032 和 Yosys 0.52 验证 Genus 网表及生成零延迟 VCD。Innovus 25.12-s079_1 反标相同样本的实际装载和计算窗口。各样本核对全部 256 个输出的 FP16 位值和地址。估计含动态和泄漏，反标在布局前进行。未覆盖的网由工具传播活动率。

| TT 100 MHz，random_0 | ref | varA | varB |
|---|---:|---:|---:|
| 任务时长（µs） | 104.33 | 36.23 | 21.91 |
| 动态功率（mW） | 14.00769 | 11.87046 | 5.59505 |
| 泄漏功率（mW） | 0.01235 | 0.01114 | 0.00564 |
| 单任务能耗（nJ） | 1,462.710 | 430.470 | 122.711 |
| VCD 覆盖率 | 99.6728% | 98.5811% | 98.9467% |

原始报告、门级窗口和波形摘要按方案与频率归档。[CSV 汇总](power/summary.csv) · [ref 100 MHz](power/ref/mhz100) · [varA 100 MHz](power/varA/mhz100) · [varB 100 MHz](power/varB/mhz100)

提前释放 erow 对同一随机任务的能耗为 138.633 → 122.711 nJ，降幅 11.5%。折叠候选进一步将能耗降到 122.438 nJ，面积比 varB 小 1.27%。两组对照均使用相同的 TT/100 MHz 设置。[晚释放功耗](power/varB-late/mhz100) · [折叠功耗](power/varB-fold/mhz100)

### 固定网表扫频

同一 `random_0` 激励覆盖 80、100、120、150 MHz。两套网表的单任务能耗变化均小于 0.06%。布局前 120 MHz 的 setup WNS 为 +0.226 ns（ref）和 +0.139 ns（varB），150 MHz 分别为 −1.357 ns 和 −1.444 ns。[扫频图](../../../docs/report/slides/figures/p4-frequency-sweep.png) · [各频点报告](power)

## 配对布局布线进度

varB 已产出布线、RC、STA 和检查报告，连通性通过，SS setup WNS 为 −0.875 ns，FF hold WNS 为 −0.421 ns。NanoRoute 记录 115,649 个 DRC 标记。当前 ref 已完成 CTS，正从检查点续跑详细布线。[后端汇总](pnr/summary.csv) · [varB 后端报告](pnr/varB)

## 复现命令

在各自干净的源码副本中，从 hw/ 运行回归。前版副本仅替换 varB 顶层。折叠版副本先应用补丁，再生成独立 golden 向量。

~~~bash
bash experiments/p4/regress-verilator.sh varB varB-early-release
# 对回归前版的副本使用历史顶层，再运行同一命令并换 TAG。
patch -p1 < experiments/p4/fold-l2e.patch
bash experiments/p4/regress-verilator.sh varB varB-fold-l2e
~~~

[完整复现说明](../../experiments/p4/README.md) · [设计报告](../../../docs/report/design-report.md) · [答辩源稿](../../../docs/report/slides/ic_slides.tex)
