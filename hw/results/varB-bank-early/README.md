# varB bank 早释放 —— 仿真原始结果

`summary.csv` 是从虚拟机 `runs/varB-early-full/summary.csv` 原样取回的，
TAG = `varB-early-full`，MODE = `full`，SEED = `20260101`，VCS V-2023.12-SP2。

| 类 | 任务 | 结果 | 周期（纯计算） | mism |
|---|---:|---|---:|---:|
| random | 200 | PASS | 1423 | 0 |
| zero | 4 | PASS | 1423 | 0 |
| extreme | 200 | PASS | 1423 | 0 |
| cancel | 200 | PASS | 1375 / 1399 / 1423 | 0 |
| reset | 4 | PASS | 1423 | 0 |
| cont | 8 | PASS | 1423 | 0 |

合计 **616 例，mism 全 0**。worst RMSE 0.002492、max\|e\| 0.006034 —— 与 1,738 拍版本逐字段相同，
说明这次改动只动调度、不动数值。

`cancel` 类的三档周期是跳过零组的既有特性（原实现同样如此），不是本次引入。

对应 `../metrics.csv` 的 `varB-bank-early-{tt,ss,ff}` 三行（`cycles` 是端到端 2,191，
`cycles_calc` 是这里的 1,423）。复跑：

> ⚠️ **已被 `../sm40-rerun-20261114/` 取代（2026-11-14 23:41）。** 本文这一轮的 tb
> 还没有 `ld` 上报，端到端 2,191 里的 768 是脚本补的；重跑后 `metrics.csv` 里
> `varB-bank-early-*` 三行已不再存在，改由 `varB-sm40-{tt,ss,ff}` 承载（同样 1,423/2,191，
> 但 `ld` 是 tb 实测的）。本目录保留作过程记录，数字与重跑结果逐位相同。

```bash
cd hw
make regress VARIANT=varB TAG=varB-early MODE=full
awk -F, 'NR>1{print $3,$7,$8,$9,$12,$13}' runs/varB-early/summary.csv
```

改动本身见 `docs/engineering/patches/12-varB-early-release.diff`。
