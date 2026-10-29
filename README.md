# 数字集成电路设计 · Transformer 注意力计算模块

2026 秋 课程设计（题目一）。目标：在 FP16 量化的 Self-Attention（Q·Kᵀ → Softmax → ·V）
上做一套可实现、可验证、可复现、并与统一参考实现成对测量的加速器。

## 目录

```
Transform/
├── docs/                  报告与理论（给人看的部分）
│   ├── assignment/        题面、评分表、附录模板
│   ├── theory/            理论分析草稿（架构对比、误差分析）
│   ├── report/            报告源（md/tex）+ 个人贡献说明
│   └── figures/           图源（svg / drawio / 生成脚本）
├── reference/             参考文献（只读，勿改）
├── hw/                    硬件工程（给芯片看的部分）→ 详见 hw/README.md
└── deliverables/          交付导出物（pdf / pptx / 压缩包，不进版本库）
```

## 两条边界

1. **`hw/` 与 `docs/` 分开**：`hw/` 里只放能被工具直接消费的东西（源码、脚本、约束、
   可复现的指标）；`docs/` 里只放叙述与图。任何"代码里的魔法数字"必须在 `docs/`
   能查到出处，任何"报告里的数字"必须能顺着 TAG 追回 `hw/runs/`。
2. **`runs/` 与 `results/` 分开**：现场 vs 结论。前者可丢，后者必须进版本库。

## 快速开始

仿真在 **CentOS 7 虚拟机**里跑（VCS 2023.12 + Verdi + Genus 15.2 已装好并实测可用）。
Windows 上只负责编辑，链路是：NAS → 共享目录 → 虚拟机本地盘。

```bash
# Windows：增量同步到共享目录
E:\candence_env\share\sync_from_nas.bat

# 虚拟机：拷到本地盘 + 打印环境自检
/root/work/prepare.sh && cd /root/work/hw

make help                      # 看方案清单与全部目标
make flowtest                  # 自检流程本身（不需要 RTL，30 秒）
make vec  SEED=20260101        # 黄金模型导出测试向量
make regress VARIANT=ref MODE=smoke
make collect                   # 汇总指标 → results/metrics.csv
```

## 状态

- [x] `model/` float64 参考 + 六类测试向量
- [x] `model/` bit-accurate 模型（含数值契约、单元自检、误差基线、位宽扫描）
- [x] `rtl/common/` 统一端口契约与包（16×16 规模、Q1{16,13} 数值格式）
- [x] `tb/sys/` 自检测试平台：一份 tb 驱动三个 DUT，逐位一致 + RMSE 双判据
- [x] `model/dumpvec.c` 向量导出器（RTL 向量唯一来源）
- [x] `flow/sim/` VCS 流程：向量 / 编译 / 单类 / 六类回归 / 流程自检
- [x] 工具链打通：虚拟机 VCS 编译+仿真实测通过，覆盖率链路验证中
- [ ] `rtl/core/` 共享数据通路
- [ ] `rtl/ref/` 统一参考实现 + 综合基准
- [ ] `rtl/varA/`
- [ ] `rtl/varB/`
- [ ] `flow/` 综合 / 功耗 / 汇总脚本
- [ ] 报告 + 个人贡献说明
