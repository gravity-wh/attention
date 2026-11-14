# 补丁暂存区

放**还没被仿真证实**的 RTL 改动。每个补丁都是可 `git apply` 的最小 diff，
配套的假设、预期拍数和验收判据写在本文件（diff 里不能带注释，会破坏格式）。

规则三条：

1. **apply 前先 `--check`**：`git apply --check <patch>`，不通过说明主干已经动过这块。
2. **验证完就要处置**：通过 → 把补丁内容正式提交进 RTL 并删掉补丁；不通过 → 删补丁，别留着。
3. **这里不放已合入的东西**。目录里存在的补丁 = 主干里还没有的改动。

| 补丁 | 目标文件 | 改动 | 预期 | 状态 |
|---|---|---|---:|---|
| `12-varB-early-release.diff` | `hw/rtl/varB/top_varB.sv` | 把 `bank_busy` 释放从 P·V 末挪到归一化末（+5/−2） | 1,738 → **1,423** 拍（−18.1%） | **已 apply，待回归** |

> ⚠️ 这条补丁**已经应用到工作区的 `top_varB.sv`**，只是还没跑回归。因此
> `git apply --check` 现在会报 `patch does not apply`——**这是预期的**，不是补丁坏了。
> 规则 1 的前提是"主干干净"，此时正确的自检是 `git diff -- hw/rtl/varB/top_varB.sv`
> 应当只含这 5 增 2 删。要回退就 `git checkout -- hw/rtl/varB/top_varB.sv`。
> 回归通过后按规则 2 把 RTL 正式提交并删掉本文件；不通过则回退并删本文件。

## 12-varB-early-release.diff

**动机**：`erow` 只有 2 个 bank，行 i 要等 C 行 i 的 P·V 走完才释放，于是行 i+2 被卡 45 拍，
16 行跑成 8×81 + 7×126 = 1,738。而 `erow` 的唯一读者是 `assign pr_mul = erow[c_bank][c_j] * c_rval`
（`top_varB.sv:211`），归一化 16 拍读完就再没人碰它——P·V 用的是 `pu_row` / `nzrow_r`。
所以 bank 可以在归一化末就放掉。

**为什么不是"必须加反压才能达标"**：A 级 81 拍/行、C 级 80 拍/行，`b2c_v` 下一拍必被消费，
1 拍余量够用。四种配置（2/3 bank × 释放点）逐拍模型都是 1,423，加不加反压一样。
但余量只有 1 拍且无断言，**建议拿到 1,423 之后再补反压 + `assert`**，把静默丢行变成挂死。

**为什么不是加第 3 个 bank**：同样是 1,423，白花 16×32 FF。

**验证**（详见 `../12-P2-工作包.md` §3.3）。注意补丁已 apply，**跳过前两步**，直接回归：

```bash
git diff --stat -- hw/rtl/varB/top_varB.sv      # 应只有 +5/−2；不是就先看是不是已被别处改动
cd hw
make regress VARIANT=varB TAG=varB-early MODE=full
awk -F, 'NR>1{print $3, $7, $8, $9, $12, $13}' runs/varB-early/summary.csv
```

判据：`lat_min == 1423` 且 `mismatch == 0`。拍数对而 mismatch 不为 0 → 立刻回退。
**2026-11-14 22:30 起仍在待验**：本机只有 iverilog 11（不支持 tb 里的 covergroup/class），
VCS 与 vsim license 均不可用，`hw/runs/` 里没有任何 `varB-early` 结果。
这一步只能在装了 VCS 的虚拟机上做。

**撤销**：`git apply --reverse <patch>` 或 `git checkout -- hw/rtl/varB/top_varB.sv`。

**预测来源**：`python hw/flow/collect/cycle_model.py --study`
（模型对现实现给 1,738、ref 9,665、varA 2,855，三者与 `metrics.csv` diff 均为 0，
所以它对这个补丁的预测不是外推而是同一套时序的重新推演）。
