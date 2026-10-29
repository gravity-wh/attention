# hw/ —— Transformer 注意力计算模块

> 本目录是「交给芯片组同事看」的部分：源码、脚本、可复现的原始结果。
> 报告与图放在仓库根的 `docs/`，交付导出物放在 `deliverables/`。

---

## 一、目录职责（一行一条，不许混用）

| 路径 | 放什么 | 不许放什么 |
|---|---|---|
| `model/` | Python 黄金模型：bit-accurate 模型 + float64 参考 + 向量生成器 | 任何 RTL 相关的分析 |
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

## 三、验证代码怎么放

### 顺序铁律：先模型，后 RTL

1. `model/ref_float64.py` —— 用 float64 算一遍，得到评分用的参考（算 RMSE / 最大绝对误差）。
2. `model/fp16_attn.py` —— **bit-accurate** 模型：逐位复现你 RTL 的量化、累加宽度、
   近似 exp、舍入方式。这是「与自身软件模型逐位一致」的比对对象，也是 RTL 的规格书。
   *RTL 写不通时先改模型，模型跑通了 RTL 只是翻译。*
3. `model/gen_vectors.py` —— 按题面要求的六类场景生成向量：
   随机 / 全零 / 正负极值 / 相消 / 复位 / 连续任务。**seed 必须写进 `meta.txt` 并进库**，
   因为报告表 1 要填「测试集版本及随机种子」。

### 三层 testbench，别混

| 层 | 位置 | 职责 |
|---|---|---|
| 单元 | `tb/unit/` | 每个 core 模块单独验，比对对象是模型的对应函数 |
| 系统 | `tb/sys/tb_top_*.sv` | 驱动统一接口、喂向量、收结果、scoreboard 比对、统计 RMSE |
| 覆盖 | `tb/cov/` | 记录六类场景都跑到，作为「验证充分」的证据 |

`tb/sys/` 里**只写一份** testbench 的公共部分（driver/scoreboard/monitor），
顶层差异靠 `+define+TOP=...` 或 `config/variants.mk` 传入，不要复制三份 tb。

### 波形

波形（`.vcd/.fsdb`）**永远不进版本库**，也**永远不写在网络盘上**——
本项目在 NAS（`//home-nas/...`）上，直接 dump 波形会把仿真拖慢一个数量级。
做法：`$dumpfile` 指向本地临时盘（如 `$::env(TMPDIR)/wave.vcd`），只在调试时开。

---

## 四、一次实验的标准动作（六步，别跳）

```bash
cd hw/

# 1. 确认工作区干净 —— 脏工作区跑出来的结果绑不到 commit，等于白跑
git status --porcelain

# 2. 生成/确认向量（首次或换 seed 时）
make vec SEED=20260101

# 3. 跑仿真，给这次实验起个能看懂的名字
make sim VARIANT=varA TAG=varA-ke8-w8

# 4. 综合 + 功耗（同一个 TAG，才能和仿真结果配对）
make syn   VARIANT=varA TAG=varA-ke8-w8
make power VARIANT=varA TAG=varA-ke8-w8

# 5. 提取指标
make collect

# 6. 在 results/EXPERIMENTS.md 记一行：commit ↔ 变量 ↔ 指标
git add -A && git commit -m "varA: KE=8, w=8 -> A=xx um2, D=xx us, E=xx nJ"
```

每次 `make` 都会写 `runs/<TAG>/INFO.txt`，里面有 commit、seed、clock、PVT、工具版本。
**这就是「复现」那 10 分的证据链**：报告里每个数字都能顺着 TAG → INFO.txt → commit 找回原始日志。

---

## 五、工具与语言子集（2026-10-29 实测）

### 本机现状

| 工具 | 位置 | 状态 |
|---|---|---|
| Icarus Verilog **12.0** | WSL2 Ubuntu 24.04 `/usr/bin/iverilog` | ✅ 已装 |
| GTKWave | 同上 | ✅ 已装 |
| Verilator 5.020 | apt 源里有，未装 | ⬜ `sudo apt install verilator` |
| VCS / Verdi 2023.12-SP2 | `H:\w1465\vcs verdi 2023.12\pkg`（Linux 安装包） | ❌ 需 Linux 虚拟机 + license，本机跑不了 |

**工程在 `//home-nas` 这个 UNC 路径上，WSL 不能直接 `cd` 进去。**
本机跑仿真的两条路：把 `hw/` 放本地盘（推荐，仿真 IO 快得多），或
`sudo mount -t drvfs '\\home-nas\MyWork' /mnt/nas`（能用但慢）。

### iverilog 12 的支持边界（决定了代码怎么写）

实测结论，写 RTL 前先记住：

| 语法特性 | iverilog 12 | 说明 |
|---|---|---|
| `package` / `typedef` / `enum` / `function` | ✅ | 已在 `attn_pkg.sv` 里用到 |
| ANSI 端口 + package 限定类型 `p::fp16_t` | ✅ | |
| `always_ff` / `always_comb` / `logic` | ✅ | |
| 宏 + 反斜杠续行的多语句块 | ✅ | 这就是端口契约用宏的原因 |
| **`interface` 出现在端口列表（`bus_if.dst b`）** | ❌ | 直接 syntax error |
| **赋值模式 `'{hi:a, lo:b}`** | ❌ | struct 逐字段赋值得老实写 |
| SVA 断言 / 功能覆盖率 / UVM | ❌ | 这三样只有 VCS 或 Verilator 能给 |

> 结论：**不要为了"写得漂亮"用 interface**。它会让本机唯一可用的仿真器直接编译失败，
> 而学校服务器上的 DC 综合又需要额外开关。宏头文件是唯一三边都通的选择。

### 需要 SVA / 覆盖率时怎么办

- 断言：iverilog 不支持，改写成 `if (cond) $display("FAIL: ..."); $finish;` 的检查块，
  效果等价，只是不那么优雅。
- 覆盖率：`tb/cov/` 里用 Python 统计"哪些场景跑过"，配合 `results/` 的表格做成证据，
  这比 Verdi 的覆盖率报告更贴题（题面要的是六类场景都覆盖，不是行覆盖率数字）。
- 真需要 UVM/Verdi 波形调试 → 找助教要实验室服务器，或按 `install_guide.pdf` 自己搭 VM。

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
