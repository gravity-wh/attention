# hw/ —— Transformer 注意力计算模块

> 本目录是「交给芯片组同事看」的部分：源码、脚本、可复现的原始结果。
> 报告与图放在仓库根的 `docs/`，交付导出物放在 `deliverables/`。

---

## 一、目录职责（一行一条，不许混用）

| 路径 | 放什么 | 不许放什么 |
|---|---|---|
| `model/` | **C** 黄金模型：bit-accurate 模型 + float64 参考 + 向量生成器 | 任何 RTL 相关的分析 |
| `rtl/common/` | `attn_pkg.sv`（类型/参数）、`attn_ports.svh`（统一端口宏） | 具体运算逻辑 |
| `rtl/core/` | 三方案**共享**的数据通路：FP16 乘加、exp LUT、累加器、SRAM 包装 | 某个方案独有的调度逻辑 |
| `rtl/ref/` `rtl/varA/` `rtl/varB/` | 该方案**独有**的顶层与引擎 + 该方案的 `filelist.f` | 三份重复的公共模块 |
| `tb/unit/` | 单元级 testbench（对着 core 里每个模块） | 顶层用例 |
| `tb/sys/` | 顶层自检测试平台（驱动统一接口 + scoreboard） | 单元测试 |
| `tb/vectors/` | 固定 seed 生成的输入向量 + `meta.txt`（**进版本库**） | 波形 |
| `tb/cov/` | 覆盖点定义、覆盖率合并脚本 | 覆盖率数据库产物 |
| `flow/` | 仿真/综合/功耗/汇总脚本 | 手敲命令的临时脚本 |
| `config/variants.mk` | 方案注册表（唯一真源） | 别处再写一份方案清单 |
| `runs/` | 每次运行的产物（**不进版本库**） | 源码 |
| `results/` | 从 runs 提取出的指标 csv/md（**进版本库**） | 原始日志 |

`runs/` 与 `results/` 的分离是全工程最重要的边界：
**runs 是现场（乱、大、可丢），results 是结论（小、干净、必须进库）。**

---

## 二、三套实现怎么放——这是整个编排的核心

题目要求「统一参考实现 / 方案 A / 方案 B」**成对测量**，且「同工艺、同工具、同工艺角、同驱动负载」。
这意味着三套实现必须是**同一个 testbench 能直接驱动**的，而不能是三份各写各的代码。

### 原则：接口共享 → 数据通路尽量共享 → 只有编排逻辑各占一坑

```
                  rtl/common/attn_ports.svh   ← 端口契约，改一次三套同时变
                            │
      ┌─────────────────────┼─────────────────────┐
      ▼                     ▼                     ▼
  rtl/ref/              rtl/varA/             rtl/varB/
  top_ref.sv            top_varA.sv           top_varB.sv
  seq_engine.sv         dot8_engine.sv        systolic_engine.sv
      │                     │                     │
      └─────────────────────┼─────────────────────┘
                            ▼
        rtl/core/  —— 共享数据通路（乘加树 / exp 近似 / 累加器 / SRAM 包装）
```

### 三条判定规则（拿不准时按这个问自己）

1. **"这个东西三个方案都要用吗？"** → 是 → `core/`；否 → 该方案目录。
2. **"改动它会让对比条件变化吗？"** → 会 → 必须放进 `core/`，让三套同时受影响，
   这样"其余条件一致"才成立；只影响一个方案的 → 放该方案目录。
3. **"这行代码是 ifdef 吗？"** → 想加 `ifdef VARIANT_A` 时，先问能不能做成
   `parameter`；不能，就说明它是结构差异，应该分文件放各自目录。
   **严禁让 ifdef 渗进 `core/` 的叶子模块**——三套代码会在一个文件里互相污染，
   答辩时没人看得懂，你自己两周后也看不懂。

### 端口契约用宏，不用 SV interface

三个顶层一字不差地这样开头：

```systemverilog
module top_ref #(parameter int SEQ_LEN = 8, D_HEAD = 64) `ATTN_TOP_PORTS;
module top_varA #(parameter int SEQ_LEN = 8, D_HEAD = 64) `ATTN_TOP_PORTS;
module top_varB #(parameter int SEQ_LEN = 8, D_HEAD = 64) `ATTN_TOP_PORTS;
```

理由见下节实测：interface 在 iverilog 上直接语法错误，在 DC/Genus 上要额外开关
才综合，而宏头文件在所有工具上都通行。**这是「本地能验」和「服务器能综合」的交集。**

### 为什么不用「三个分支」或「三个仓库」

- 分支：切来切去没法同时综合、同时对比，而且公共 bug 修复要 rebase 三次，
  忘记同步一次对比就失真了。
- 三仓库：`core/` 的改动要手工复制三遍，必然漂移。
- 结论：**目录并行 + 共享 core + flist 隔离**。git 只用来记录时间轴，不用来隔离方案。

---

## 三、验证架构：一份 tb 驱动三个 DUT

### 顺序铁律：先模型，后 RTL

1. `model/attn_model.c`（`attn_ref()`）—— 用 float64 算一遍，得到评分用的参考（算 RMSE / 最大绝对误差）。
2. `model/attn_model.c`（`attn_fixed()`）—— **bit-accurate** 模型：逐位复现你 RTL 的量化、累加宽度、
   近似 exp、舍入方式。这是「与自身软件模型逐位一致」的比对对象，也是 RTL 的规格书。
   *RTL 写不通时先改模型，模型跑通了 RTL 只是翻译。*
   数值契约（位宽 / 小数位 / LUT / 舍入）写在 `model/attn_model.h` 顶部，
   设计依据写在 `docs/theory/01-数值格式设计.md`。
3. `model/vecgen.c` + `model/dumpvec.c` —— 按题面要求的六类场景生成向量，
   并直接导出成 tb 能 `$readmemh` 的文件。**seed 必须记录并进库**，
   因为报告表 1 要填「测试集版本及随机种子」。

> **为什么向量必须由 C 模型导出，而不是另写一个 Python 脚本重算一遍**：
> "逐位一致的软件模型"和"测试向量"必须出自**同一份代码**。只要多一条重新实现的路径，
> 就多一个不一致的来源——而那正是这项要被扣分的地方。

### 向量契约（tb 依赖它，改格式 = 改 tb）

`flow/sim/genvec.sh` 把每个任务写成三个文件，每行一个值：

| 文件 | 内容 |
|---|---|
| `<cat>_<idx>_qkv.hex` | 768 个 16 bit：`Q[0..255] K[256..511] V[512..767]`，行主序 |
| `<cat>_<idx>_exp.hex` | 256 个 16 bit：**逐位一致**的期望输出（FP16 位模式） |
| `<cat>_<idx>_ref.hex` | 256 个 64 bit：float64 参考值，tb 用 `$bitstoreal` 还原后算 RMSE |

还有 `manifest.txt` 记 seed、定点配置（qb/qf/lut）、任务清单、以及每行的 Σp 偏差。
`cat` 取 `random / zero / extreme / cancel / reset / cont` 六个短名。

两档规模：`MODE=smoke` 每类 2 个任务（37 个文件、约 110 KB，**进版本库**）；
`MODE=full` 共 616 个任务（1849 个文件、9.8 MB，按需生成、不进库，但 seed 进库）。

### 一份 tb，三个 DUT

```
                    tb/sys/tb_attn.sv        ← 驱动 / 采样 / scoreboard / 覆盖率，只写一份
                            │
              +define+DUT=top_ref  (或 top_varA / top_varB)
                            ▼
      ┌──────────────┬──────────────┬──────────────┐
   top_ref        top_varA       top_varB      ← 各自 filelist.f 隔离
      └──────────────┴──────────────┴──────────────┘
                            ▼
                  rtl/core/  共享数据通路
```

编译时用 `+define+DUT=top_xxx` 注入被测顶层，三个方案共用同一份驱动、同一份判据、
同一份覆盖率——**对比条件天然成立**，不靠人守着。

### 两条判据同时成立才算 PASS

| 判据 | 含义 | 阈值 |
|---|---|---|
| 逐位一致 | 输出 FP16 与 C 定点模型 bit-exact | 0 个元素不同 |
| 精度达标 | 对 float64 参考的 RMSE / 最大绝对误差 | ≤ 0.06 / ≤ 0.20 |
| 有限值 | 输出不含 inf / NaN | 0 个 |

只过第一条 → RTL 忠实于一个错误的模型；只过第二条 → 模型和 RTL 不是一回事。
两条都过，才说明"这个 RTL 实现了那个模型，而那个模型精度够用"。

### 六类激励怎么落到 tb 里

| 类别 | 向量 | tb 侧额外做的事 |
|---|---|---|
| `random` | 均匀随机 ∈[-2,2] | —— |
| `zero` | 全零；奇数号只让 V 非零 | 查 0/0 不产生 NaN |
| `extreme` | {-2,-1,0,1,2}，强制第 0 行全 +2、第 1 行全 -2 | 打饱和与符号对称 |
| `cancel` | Hadamard 正交 / 近并行 K 行交替 | 打累加器与 softmax 分辨率 |
| `reset` | 随机任务 | **复位后重跑，两次输出必须逐位相同** |
| `cont` | 随机任务，**不复位**连续跑 | 与干净状态的期望值比对，查状态泄漏 |

### 覆盖率：能采，但出不了 urg 报告（license 限制）

`tb_attn.sv` 里用 `covergroup` 采样四类点：类别、时延桶、是否失配、RMSE 分布，
外加 `lat × mismatch` 交叉。实测结论：

| 环节 | 状态 |
|---|---|
| `vcs -cm line+cond+fsm+tgl+branch` 编译 | ✅ 通过 |
| `simv -cm ...` 仿真、产生 `simv.vdb` | ✅ 通过 |
| **`urg -dir simv.vdb` 出报告** | ❌ **崩在 `covdb_get_license()`，这台机器的 license 不含 URG 特性** |

所以 `flow/sim/build.sh` **默认不开 `-cm`**（采了也没法出报告，只是拖慢仿真）。
需要行/条件覆盖率数字时：`CM=1 make sim ...`，然后接受"数据在 vdb 里、报告要换台有 license 的机器出"。

**报告里怎么写**：题面要的是"六类激励都覆盖到"，不是行覆盖率百分比。
所以证据链是 `results/` 里六类回归表（每类一行、状态 PASS）+ `runs/<TAG>/sim_<cat>.log`，
而不是一个覆盖率百分比数字。这样反而更贴题，也不依赖 license。

### 波形

波形（`.vcd/.fsdb`）**永远不进版本库**，也**永远不写在网络盘上**。
`tb_attn.sv` 只在 `+DUMP=1` 时开 dump，默认关——回归时开着会慢一个数量级。
看到失配再单独开一次，用 Verdi 打开。

---

## 四、一次实验的标准动作（七步，别跳）

所有命令都在**虚拟机里的 `/root/work/hw`** 执行（环境变量见第五节）。

```bash
cd /root/work/hw

# 0. 确认流程本身是好的（第一次跑、或改了 tb 之后必做）
make flowtest

# 1. 确认工作区干净 —— 脏工作区跑出来的结果绑不到 commit，等于白跑
git status --porcelain

# 2. 生成/确认向量（首次或换 seed 时）
make vec SEED=20260101 MODE=smoke     # 日常
make vec SEED=20260101 MODE=full      # 出报告数据前

# 3. 单类激励调试（快，出问题先看这个）
make sim VARIANT=ref CAT=random N=2 VERBOSE=1

# 4. 六类全跑（回归）—— MODE 必须与第 2 步一致
make regress VARIANT=ref TAG=ref-smoke MODE=smoke
make regress VARIANT=ref TAG=ref-full  MODE=full

# 5. 综合 + 功耗（同一个 TAG，才能和仿真结果配对）
make syn   VARIANT=ref TAG=ref-full
make power VARIANT=ref TAG=ref-full

# 6. 提取指标
make collect

# 7. 在 results/EXPERIMENTS.md 记一行：commit ↔ 变量 ↔ 指标
git add -A && git commit -m "ref: 基准 -> RMSE=xx, A=xx um2, D=xx us, E=xx nJ"
```

每次 `make sim/regress` 都会写：

| 产物 | 内容 |
|---|---|
| `runs/<TAG>/INFO.txt` | commit、seed、clock、PVT、工具版本、工作区是否干净 |
| `runs/<TAG>/build.log` | 完整编译日志 |
| `runs/<TAG>/sim_<cat>.log` | 该类别的完整仿真日志（含 `[SUMMARY]` 机器可读行） |
| `runs/<TAG>/summary.csv` | 每个类别一行指标，`make table` 直接吃这个 |

**这就是「复现」那 10 分的证据链**：报告里每个数字都能顺着 TAG → INFO.txt → commit 找回原始日志。

---

## 五、工具栈与运行环境（2026-10-29 实测）

### 三层分工

| 环节 | 在哪做 | 说明 |
|---|---|---|
| 写代码 / 编辑 | Windows（NAS 上的工程） | NAS 是唯一真源，git 在这里 |
| **仿真 / 覆盖率 / 波形** | **CentOS 7 虚拟机** | VCS V-2023.12-SP2 + Verdi + URG，license 正常 |
| **综合 / 功耗** | **同一台虚拟机** | Cadence **Genus 15.2**（`/opt/cadence/GENUS152`） |
| 快速语法检查 | 虚拟机里 VCS 编译（1~2 秒） | 见下：iverilog 已退役 |

**结论：不要再往 Windows 或 WSL 上装仿真器。** 虚拟机里 VCS 编译这个规模的 RTL
只要 1~2 秒，比"先装个 iverilog 本地跑一遍再同步"还快，而且少一条工具链要维护。

### 虚拟机里的既有环境（别人已经装好的，直接用）

```
VCS_HOME    = /root/synopsys_apps/vcs/vcs/V-2023.12-SP2      （14 GB）
VERDI_HOME  = /root/synopsys_apps/verdi/verdi/V-2023.12-SP2  （23 GB）
SCL_HOME    = /root/synopsys_apps/scl/2021.03                （license 守护）
license     = 27000@localhost.localdomain，FLEXlm host ID 000c293bbc9b
Genus       = /opt/cadence/GENUS152/bin/genus
```

环境变量写在 `/etc/profile.d/synopsys.sh`，并在 `/etc/bashrc` 里兜底 source，
所以**登录 shell、`bash -c`、`make` 子进程都能拿到**（早期只写在 root 的 `.bashrc` 里，
`make` 拿不到，这是最容易踩的坑）。

### 主机 ↔ 虚拟机 通道

```bat
:: Windows 侧：NAS → 共享目录（增量，排除 runs/.git/波形/可执行）
E:\candence_env\share\sync_from_nas.bat
```

```bash
# 虚拟机侧：共享目录 → 本地盘再编译
/root/work/prepare.sh
```

两条铁律：

1. **绝不在 `/mnt/hgfs` 上直接跑仿真**。hgfs 走 FUSE，写 `simv` 中间文件和覆盖率数据库
   会慢一个数量级。`prepare.sh` 就是干这件事的：先 `cp -a` 到 `/root/work/hw` 再动手。
2. **调用 `vmrun.exe` 必须设 `MSYS_NO_PATHCONV=1`**。否则 Git Bash 会把客户机路径
   `/bin/echo` 自动转成 Windows 路径，报"文件未找到"，而错误信息完全指不到真因。
   另外 `vmrun` 会一直阻塞到客户机命令结束，长任务要放到受管后台里跑，别用 `&`。

### 为什么 iverilog 退役了

上一版方案为了在 WSL 里快跑，把端口契约从 SV `interface` 改成了宏头文件——这个决定**依然正确**
（interface 在 Genus 上要额外开关，而接口跨工具一致是硬需求）。但现在有了 VCS，
iverilog 的唯一优势（不需要 license）就不成立了，而它的三项缺失是硬伤：

| 能力 | iverilog 12 | VCS |
|---|---|---|
| SVA 断言 | ❌ | ✅ |
| 功能覆盖率（covergroup + urg 报告） | ❌ | ✅ |
| UVM | ❌ | ✅（`$VCS_HOME/etc/uvm`） |
| 波形给 Verdi 看 | ⚠ 只有 VCD | ✅ FSDB / KDB |

验证占 30 分，其中"验证充分性"要靠覆盖率说话，这条只有 VCS 能给。所以**单一仿真器：VCS**。

### 语言子集（写 RTL 时的约束）

宏头文件 + `package` 这套写法在 VCS / Verilator / Genus 上全部通过，已实测。
仍然建议遵守：

- 端口契约用 `` `ATTN_TOP_PORTS `` 宏，不用 `interface`（Genus 要额外开关，面积容易踩坑）
- 不用 `'{...}` 赋值模式（可读性收益小于工具兼容风险）
- 状态机用 `enum`，别用裸 `parameter`（波形里能直接显示状态名）

---

## 六、版本管理规则

### 仓库

单仓库（mono-repo），`Transform/` 整个作为 git 根。原因：报告表格里一个数字同时依赖
模型、RTL、脚本、约束文件，拆成多仓库后"哪一版配哪一版"永远说不清。

### 分支怎么用

- `main`：随时可复现的状态，**每次 `git push` 前必须能 `make sim` 全绿**。
- `feat/<方案>-<要点>`：开发中。例：`feat/varA-ke8`、`feat/varB-systolic`。
- **绝不用分支来区分方案**。分支区分的是"做完了没"，目录区分的是"是哪个方案"。

### tag 怎么打

```
m0.1-model      float64 参考 + 六类向量就绪
m0.2-model      bit-accurate 模型与 RTL 逐位一致
r1-ref          ref 综合通过，拿到基准 A0/D0/E0
a1-varA         varA 达标
b1-varB         varB 达标
sub-v1          提交版（导出交付包的那一版）
```

### 提交纪律

- 一个 commit 只做一件事：`rtl: add fp16 multiplier` / `tb: add scoreboard RMSE check`。
- **禁止** `git add -A && git commit -m "update"`——三周后你没法靠它回滚任何东西。
- 大文件红线：单文件 > 20MB 不进库；网表/gds/报告 pdf 放 `deliverables/`（已 gitignore），
  用 release 附件或网盘交付。

### 提交时怎么打包

```bash
git tag -a sub-v1 -m "课程设计提交版"
git archive --format=zip --prefix=Transform/ sub-v1 -o ../Transform_sub_v1.zip
```

`git archive` 天然只含被跟踪的文件——`runs/`、波形、综合产物自动被排除，
不会像直接压缩文件夹那样把几十 GB 垃圾一起交上去。

### 原始结果怎么交

`runs/` 不进库，但**要交**。做法：只挑支撑报告表格的那几次运行，
压成 `deliverables/raw_runs_<tag>.zip` 单独提交给助教，并在 `docs/report/` 里点名
用到的是哪几个 TAG。

### 个人贡献说明（题面明确要求）

`docs/report/contributions.md` 里按人写清参与内容，用
`git shortlog -sn --no-merges` 和
`git log --author="<name>" --oneline` 的输出作为佐证附在后面。

---

## 七、新人上手 3 分钟

```bash
cd hw/
make help          # 看所有目标、三个方案、当前变量
make vec          # 生成向量
make sim VARIANT=ref TAG=ref-smoke
```

只需要记住一条：**任何流程改动都先进 `flow/` 再进 `Makefile`，不许手敲工具命令。**
