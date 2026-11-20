# P4 实验记录

基线为仓库的 ref，优化方案为 varB。RTL 锚点为 9cdb03cef13a7badc2fb8c88b0cba6bc96c4ab67。测量使用 SMIC 40LL、SC9MC RVT r1p1，综合角 TT 1.10 V、25 °C，主时钟 100 MHz。历史 Genus 15.20 的三方案表 2 见 [11 月 14 日归档](../sm40-rerun-20261114)。新跑工具与条件按各表记录。

## RTL 复测

- 模拟器为 [Verilator 5.032](rtl/verilator-version.txt)，完整向量 seed 为 20260101。三次 varB 回归均为 616/616 通过、逐位失配 0，装载均实测为 768 拍。
- 表 3 调整前从 3c381e0 的 top_varB.sv 取顶层，其余 RTL、模型、向量、testbench 与调整后相同。归一化结束释放指数缓冲后，纯计算 1,738 → 1,423 拍，完整任务 2,506 → 2,191 拍，时延降低 12.6%。两版最大 RMSE 和绝对误差完全一致。
- 折叠候选在 K 装载时进行定点换底，并由配套的 C 模型产生该候选的逐位期望值。折叠前后的 float64 参考相同。最大 RMSE 从 0.002492 增至 0.003656，最大绝对误差从 0.006034 增至 0.008309，两者均在题面阈值内。最坏完整任务保持 2,191 拍。

| 实验 | 原始汇总 | 复现输入 |
|---|---|---|
| varB 晚释放 | [前版 616 项](rtl/varB-late-release.csv) | [历史顶层](https://github.com/gravity-wh/attention/blob/3c381e0b03609e4c595188d43bb2b0b546da8152/hw/rtl/varB/top_varB.sv) |
| varB 早释放 | [现版 616 项](rtl/varB-early-release.csv) | 主分支 RTL |
| fold_l2e | [候选 616 项](rtl/varB-fold-l2e.csv) | [隔离试验补丁](../../experiments/p4/fold-l2e.patch) |

## 复现命令

在各自干净的源码副本中，从 hw/ 运行回归。前版副本仅替换 varB 顶层。折叠版副本先应用补丁，再生成独立 golden 向量。

~~~bash
bash experiments/p4/regress-verilator.sh varB varB-early-release
# 对回归前版的副本使用历史顶层，再运行同一命令并换 TAG。
patch -p1 < experiments/p4/fold-l2e.patch
bash experiments/p4/regress-verilator.sh varB varB-fold-l2e
~~~

[设计报告](../../../docs/report/design-report.md) · [答辩源稿](../../../docs/report/slides/ic_slides.tex)
