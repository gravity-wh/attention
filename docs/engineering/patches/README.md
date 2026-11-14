# 补丁暂存区

放**还没被仿真证实**的 RTL 改动。每个补丁都是可 `git apply` 的最小 diff，
配套的假设、预期拍数和验收判据写在本文件（diff 里不能带注释，会破坏格式）。

规则三条：

1. **apply 前先 `--check`**：`git apply --check <patch>`，不通过说明主干已经动过这块。
2. **验证完就要处置**：通过 → 把补丁内容正式提交进 RTL，补丁文件保留作评审存档并标「已合入」；
   不通过 → 回退并删补丁，别留着。
3. **目录里的补丁 = 一份可回退的改动记录**。状态列写清它是否已在主干里。

| 补丁 | 目标文件 | 改动 | 预期 | 状态 |
|---|---|---|---:|---|
| `12-varB-early-release.diff` | `hw/rtl/varB/top_varB.sv` | 把 `bank_busy` 释放从 P·V 末挪到归一化末（+5/−2） | 1,738 → **1,423** 拍（−18.1%） | **已实测通过，已合入主干** |

> ✅ **2026-11-14 实测结论**：616 例全 PASS、`mism 0`、`lat 1423`（smoke 12 例与 full 616 例一致）；
> 三角重综合 WNS 全 ≥ 0（最差 +0.001 ns），面积/功耗变化在 ±0.9% 内。
> 因此这条补丁**已经写进 `hw/rtl/varB/top_varB.sv`**，现在再 `git apply` 会报
> `patch does not apply`——那是正常的。要回退就用 `git apply --reverse <patch>`。
> 实测账见 `../05-SMIC40综合结果.md` §3.3 与 `../12-P2-工作包.md` §3.4。

## 12-varB-early-release.diff

**动机**：`erow` 只有 2 个 bank，行 i 要等 C 行 i 的 P·V 走完才释放，于是行 i+2 被卡 45 拍，
16 行跑成 8×81 + 7×126 = 1,738。而 `erow` 的唯一读者是 `assign pr_mul = erow[c_bank][c_j] * c_rval`
（`top_varB.sv:211`），归一化 16 拍读完就再没人碰它——P·V 用的是 `pu_row` / `nzrow_r`。
所以 bank 可以在归一化末就放掉。

**为什么不是"必须加反压才能达标"**：A 级 81 拍/行、C 级 80 拍/行，`b2c_v` 下一拍必被消费，
1 拍余量够用。四种配置（2/3 bank × 释放点）逐拍模型都是 1,423，加不加反压一样。
但余量只有 1 拍且无断言，**建议拿到 1,423 之后再补反压 + `assert`**，把静默丢行变成挂死。

**为什么不是加第 3 个 bank**：同样是 1,423，白花 16×32 FF。

**验证结果**（2026-11-14，CentOS 7.9 VM，VCS V-2023.12-SP2，seed 20260101）：

| 项 | 结果 |
|---|---|
| smoke（12 例） | 六类全 PASS，`lat 1423` |
| full（616 例） | 六类全 PASS，`mism 0`，`lat_min = lat_avg = lat_max = 1423` |
| cancel 类 | `lat 1375 / 1399 / 1423`（跳过零组变快，原有特性，不是回归） |
| 精度 | worst RMSE 0.002492、max\|e\| 0.006034 —— 与原实现逐字段相同 |
| 三角综合 | WNS 0 / 0 / +0.001；面积 73,296.9 / 83,004.8 / 67,074.6 µm²；功耗 16.096 / 14.806 / 18.463 mW |

复跑命令（补丁已在主干里，不需要再 apply）：

```bash
cd hw
make regress VARIANT=varB TAG=varB-early MODE=full
awk -F, 'NR>1{print $3, $7, $8, $9, $12, $13}' runs/varB-early/summary.csv
```

判据：`lat_min == 1423` 且 `mismatch == 0`。拍数对而 mismatch 不为 0 → 立刻回退。

**撤销**：`git apply --reverse <patch>` 或 `git checkout <commit> -- hw/rtl/varB/top_varB.sv`。

**预测来源**：`python hw/flow/collect/cycle_model.py --study`
（模型对现实现给 1,738、ref 9,665、varA 2,855，三者与 `metrics.csv` diff 均为 0，
所以它对这个补丁的预测不是外推而是同一套时序的重新推演）。
