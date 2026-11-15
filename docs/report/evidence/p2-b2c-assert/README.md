# P2 b2c 断言回归证据（2026-11-15）

> 目的：证明 `[VARB-B2C]` / `[VARB-A2B]` 不再只是打印语句，而是会让 `run.sh` 判 FAIL。
> 本目录是证据索引；完整的干净 full 日志、故障日志和源码归档都在本目录内，新 clone 可直接复核。

## 1. 干净 full 回归

```text
tag      : p2-b2c-assert-final
commit   : 783149f
variant  : varB
seed     : 20260101
clock    : 100 MHz
pvt      : TT_25C_1V10
pdk      : SC9MC
```

命令：

```bash
cd hw
make regress VARIANT=varB TAG=p2-b2c-assert-final MODE=full
```

结果：

```text
random  200/200 PASS  lat 1423  ld 768  mism 0
zero      4/4   PASS  lat 1423  ld 768  mism 0
extreme 200/200 PASS  lat 1423  ld 768  mism 0
cancel  200/200 PASS  lat 1375/1399/1423  ld 768  mism 0
reset     4/4   PASS  lat 1423  ld 768  mism 0
cont      8/8   PASS  lat 1423  ld 768  mism 0
assert_hits = 0
```

- `clean/INFO.txt`：commit `783149f`、ld=768。
- `clean/summary.csv`：六类 616 例全 PASS。
- `clean/logs/`：六类原始 `sim_*.log` 与 `.log.stdout`。

> **`dirty 0` 的边界**：VM 副本没有 `.git`，`git diff --name-only HEAD` 失败后 `wc -l` 仍输出 0，
> 因此这个字段在 VM 里**不是**源码干净性的证据。干净性由下面的源码归档校验保证。

## 2. 源码归档与哈希

`source-783149f.tar` 是用：

```bash
git archive --format=tar -o source-783149f.tar 783149f -- \
  hw/rtl hw/flow/sim hw/flow/collect/cycle_model.py hw/tb hw/model hw/config
```

生成的受控源码集；`SOURCE_SHA256SUMS` 是展开后 105 个文件的哈希清单。

校验：

```bash
sha256sum -c SOURCE_ARCHIVE.sha256
mkdir /tmp/p2-src && tar -xf source-783149f.tar -C /tmp/p2-src
cd /tmp/p2-src && sha256sum -c /path/to/SOURCE_SHA256SUMS
```

RTL 哈希：

```text
hw/rtl/varB/top_varB.sv sha256
066757aaa4c5f51f3efe8eb1e705d62d21ae02897cac812bea544085f53c5dcf
```

## 3. 受控故障注入：b2c

补丁：`fault/inject-b2c.patch`

```bash
git apply fault/inject-b2c.patch
```

它只改 C 级消费分支：

```diff
-            b2c_v   <= 1'b0;
+            b2c_v   <= 1'b1;
```

运行：

```bash
make sim VARIANT=varB TAG=inject-b2c-final CAT=random N=2 MODE=smoke
```

观察：

```text
[SUMMARY] cat=random tasks=2 pass=2 fail=0 ... status=PASS
[VARB-B2C] b2c_v held more than 2 cycles: ...
[VARB-B2C] B would overwrite pending b2c_v: ...
✗ DUT 握手断言触发（2620 条）—— 这不是普通 log，判 FAIL
```

摘要：

```text
inject-b2c-final,varB,random,2,0,2,-1,-1,-1,-1,-1,-1,FAIL,0
```

这证明了两件事：

1. **testbench 仍会打印 `status=PASS`** —— 仅靠 tb 的 PASS/FAIL 不能拦住断言；
2. 修好的 `run.sh` 在 `[SUMMARY]` 之前检查 `[VARB-(B2C|A2B)]`，检测到 2620 条后直接写 `FAIL` 并退出 1。

b2c 断言分类：

| 类型 | 行数 |
|---|---:|
| `b2c_v held more than 2 cycles` | 2,590 |
| `B would overwrite pending b2c_v` | 30 |
| 合计 | **2,620** |

证据文件：

- `fault/summary.csv`：单次 `make sim` 的 `FAIL` 行；
- `fault/assert_random.log`：2,620 条断言原文；
- `fault/regress-smoke-summary.csv`：故障模式下 `make regress ... MODE=smoke` 的六类 `FAIL` 摘要；
- `fault/regress-smoke.log.gz`：上述 `make regress` 的完整控制台日志（gzip）；
- `fault/sim_random.log`、`fault/sim_random.log.stdout`：原始仿真日志。

故障模式整条回归链也已实测：

```text
make regress VARIANT=varB TAG=inject-b2c-regress MODE=smoke
→ 未通过: random zero extreme cancel reset cont
→ make: *** [regress] Error 1
```

## 4. 受控故障注入：a2b

补丁：`fault-a2b/inject-a2b.patch`

```bash
git apply fault-a2b/inject-a2b.patch
```

它只改 B 级握手：

```diff
-            a2b_v        <= 1'b0;
+            a2b_v        <= 1'b1;
```

运行后共产生 **4,394 条**握手断言：

| 类型 | 行数 |
|---|---:|
| `[VARB-A2B]` | **2,680** |
| `[VARB-B2C]` | **1,714** |
| 合计 | **4,394** |

`run.sh` 对两类合计计数并判 `FAIL`；摘要：

```text
inject-a2b-final,varB,random,2,0,2,-1,-1,-1,-1,-1,-1,FAIL,0
```

## 5. 代码改动

`hw/flow/sim/run.sh` 新增：

```bash
ASSERT_HITS=$(grep -E '\[VARB-(B2C|A2B)\]' "$LOG" 2>/dev/null || true)
if [ -n "$ASSERT_HITS" ]; then
    ...
    echo "$TAG,$VARIANT,$CAT,$N,0,$N,-1,-1,-1,-1,-1,-1,FAIL,0" >> "$RUN/summary.csv"
    exit 1
fi
```

该检查放在 timeout 判定之前，所以“断言 + 超时”也会先报断言，而不是被 TIMEOUT 掩盖。

> **数值字段约定**：失败行的 `-1` 表示“未采集”，不是实测 RMSE/MaxAE/mismatch 为零。
> a2b 故障本身已经产生了真实 mismatch，外层 `FAIL` 行不能把 `mismatch` 写成 0。

`hw/flow/collect/cycle_model.py` 的 early-release 分支改为跟踪 `b_bank`，不再用 `a2b_b` 近似 `b2c_b`；1,738/1,423 结果不变，但 bank 身份路径可复核。

## 6. 复现边界

- 本次只重跑 VCS 仿真，**没有重跑 Genus**；`translate_off` 断言不进入综合网表，PPA 仍沿用 main 的九角结果，不能声称新网表等价已验证。
- 故障注入是临时副本，不在提交里；干净分支的 RTL 与 `783149f` 一致。
- 故障注入只跑到 `MODE=smoke`；它证明“断言会触发且整条 regress 会非零退出”，不证明六类全量故障覆盖。
- 新 clone 验收：

```bash
cd docs/report/evidence/p2-b2c-assert
sha256sum -c SHA256SUMS
sha256sum -c SOURCE_ARCHIVE.sha256
# README 引用的 fault/*.patch、fault/*.log、fault-a2b/*.log 必须都存在
```
