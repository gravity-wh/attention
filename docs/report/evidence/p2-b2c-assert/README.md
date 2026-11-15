# P2 b2c 断言回归证据（2026-11-15）

> 目的：证明 `[VARB-B2C]` / `[VARB-A2B]` 不再只是打印语句，而是会让 `run.sh` 判 FAIL。
> 本目录是证据索引；原始大批日志在 `P2_EVIDENCE` 和 VM `runs/` 下，哈希见 `SHA256SUMS`。

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

- `clean/INFO.txt`：commit `783149f`、dirty 0、ld=768。
- `clean/summary.csv`：六类 616 例全 PASS。
- `clean/logs/`：六类原始 `sim_*.log` 与 `.log.stdout`。

RTL 哈希：

```text
hw/rtl/varB/top_varB.sv sha256
066757aaa4c5f51f3efe8eb1e705d62d21ae02897cac812bea544085f53c5dcf
```

## 2. 受控故障注入：强制 b2c_v 多保持

在临时副本中把 `top_varB.sv` 的 C 级消费分支：

```systemverilog
b2c_v <= 1'b0;
```

改成：

```systemverilog
b2c_v <= 1'b1;
```

只改这一行，不提交。运行：

```bash
make sim VARIANT=varB TAG=inject-b2c2 CAT=random N=2 MODE=smoke
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
inject-b2c2,varB,random,2,0,2,-1,-1,-1,0,0,0,FAIL,0
```

这证明了两件事：

1. **testbench 仍会打印 `status=PASS`** —— 仅靠 tb 的 PASS/FAIL 不能拦住断言；
2. 修好的 `run.sh` 在 `[SUMMARY]` 之前检查 `[VARB-(B2C|A2B)]`，检测到 2620 条后直接写 `FAIL` 并退出 1。

证据文件：

- `fault/summary.csv`：`FAIL` 行；
- `fault/assert_random.log`：2620 条断言原文；
- `SHA256SUMS`：本目录文件哈希。

## 3. 代码改动

`hw/flow/sim/run.sh` 新增：

```bash
ASSERT_HITS=$(grep -E '\[VARB-(B2C|A2B)\]' "$LOG" 2>/dev/null || true)
if [ -n "$ASSERT_HITS" ]; then
    ...
    echo "$TAG,$VARIANT,$CAT,$N,0,$N,-1,-1,-1,0,0,0,FAIL,0" >> "$RUN/summary.csv"
    exit 1
fi
```

该检查放在 timeout 判定之前，所以“断言 + 超时”也会先报断言，而不是被 TIMEOUT 掩盖。

`hw/flow/collect/cycle_model.py` 的 early-release 分支改为跟踪 `b_bank`，不再用 `a2b_b` 近似 `b2c_b`；1,738/1,423 结果不变，但 bank 身份路径可复核。

## 4. 复现边界

- 本次只重跑 VCS 仿真，**没有重跑 Genus**；`translate_off` 断言不进入综合网表，PPA 仍沿用 main 的九角结果，不能声称新网表等价已验证。
- 故障注入是临时副本，不在提交里；干净分支的 RTL 与 `783149f` 一致。
- 原始 full 日志同时保存在本机 `C:\Users\18611\Desktop\DigitaIC_Work\P2_EVIDENCE\clean\`；本目录只放小日志和索引，避免仓库膨胀。
