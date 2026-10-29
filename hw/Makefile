# =====================================================================
#  hw/Makefile —— 本工程唯一的流程入口
#  规则：任何时候不要手敲 iverilog/vcs/dc_shell，一律 make <target>。
#        理由：报告要「原始结果 + 脚本 + 版本」，手敲的命令没法复现。
#
#  常用：
#    make vec  SEED=20260101
#    make sim  VARIANT=varA TAG=varA-ke8-w8
#    make syn  VARIANT=varA TAG=varA-ke8-w8
#    make power VARIANT=varA TAG=varA-ke8-w8
#    make collect      # 扫 runs/ → results/metrics.csv
#    make table        # metrics.csv → 报告用 markdown 表格
# =====================================================================
SHELL := /bin/bash
include config/variants.mk
include config/pdk.mk

VARIANT ?= ref
TAG     ?= $(VARIANT)
SEED    ?= 20260101
SIM     ?= vcs
SYN     ?= genus
PY      ?= python3

# ---- 仿真相关的默认档位 ------------------------------------------------
# CAT：六类激励之一；日常迭代用 random，看细节用 VERBOSE=1
CAT     ?= random
N       ?= 2
VERBOSE ?= 0
# MODE：smoke=每类 2 个任务（秒级）；full=每类按模型设定（分钟级）
MODE    ?= smoke

RUN     := runs/$(TAG)
FLIST   := rtl/$(VARIANT)/filelist.f
TOP     := $(top_$(VARIANT))
CLOCK   := $(clock_$(VARIANT))
VECDIR  := tb/vectors/s$(SEED)

# 数值格式：从 config/variants.mk 按方案取，绝不在脚本里另写一份默认值。
# CFGTAG 同时决定三处：C 模型导出哪个黄金值、RTL 编译时的 Q_BITS/Q_FRAC、
# tb 读哪个 exp 文件。三者同源，才不会出现"向量按 16bit 生成、RTL 按 10bit 综合"。
QB      := $(qb_$(VARIANT))
QF      := $(qf_$(VARIANT))
LUT     := $(lut_$(VARIANT))
CFGTAG  := qb$(QB)qf$(QF)

export VARIANT TAG SEED RUN FLIST TOP CLOCK PVT MODE CAT N VERBOSE QB QF LUT CFGTAG

# 综合相关的变量也导出：run_syn.sh / syn.tcl 只从环境读，不自己解释 config。
export PDK CORNER SYN_LIB SYN_LEF SYN_DRIVE_CELL SYN_LOAD_PF \
       SYN_CLK_UNCERT_PCT SYN_IO_DELAY_PCT SYN_TOGGLE_RATE SYN_STATIC_PROB

.PHONY: all help check model modeltest err vec vecfsck vecfsck1 cfgof sim regress flowtest unit unitall lint syn synall power pdkcheck collect table manifest preflight clean

# 说明：这里刻意不用 shell 循环做变量间接引用——
#       某些 Windows 环境下长命令行里的非 ASCII 会被截断，导致引号失配。
#       值仍然从 config/variants.mk 取，新增方案时在这里补一行即可。

help:
	@echo "-- targets ----------------------------------------------------"
	@echo "  make model                           编译数值模型（无 EDA 依赖）"
	@echo "  make modeltest                       模型单元自检（fp16/定点/exp2/端点）"
	@echo "  make err     SEED=...                误差基线 -> results/error_baseline.txt"
	@echo "  make vec     SEED=... MODE=smoke|full VARIANT=<v>  黄金模型导出 RTL 向量"
	@echo "  make vecfsck  SEED=...               回读校验：向量是否仍与模型一致"
	@echo "  make flowtest                        自检流程本身（不需要 RTL）"
	@echo "  make unit     VARIANT=<v>            四个数值件的单元穷举对拍"
	@echo "  make unitall                         所有方案的单元对拍（验参数化）"
	@echo "  make sim     VARIANT=<v> CAT=<c>      编一个方案 + 跑一类激励"
	@echo "  make regress VARIANT=<v> MODE=full    一个方案跑完六类（回归）"
	@echo "  make lint    VARIANT=<v>             RTL 静态检查"
	@echo "  make syn     VARIANT=<v> TAG=<t>     ASIC 综合（面积 / 时序）"
	@echo "  make power   VARIANT=<v> TAG=<t>     看已跑综合的功耗（同一次综合，无独立功耗工具）"
	@echo "  make synall  VARIANT=<v> TAG=<t>     tt/ss/ff 三个角各综合一遍"
	@echo "  make pdkcheck                        打印工艺库/约束参数（综合前自检）"
	@echo "  make collect                         汇总 runs/ -> results/metrics.csv"
	@echo "  make table                           生成报告用 markdown 表格"
	@echo "  make manifest VARIANT=<v> TAG=<t>    写本次运行的可复现清单"
	@echo "  make clean                           清掉运行产物（保留 runs/ 里的报告）"
	@echo "-- variants ---------------------------------------------------"
	@echo "  ref    $(top_ref)     $(strip $(clock_ref)) MHz   $(desc_ref)"
	@echo "  varA   $(top_varA)    $(strip $(clock_varA)) MHz   $(desc_varA)"
	@echo "  varB   $(top_varB)    $(strip $(clock_varB)) MHz   $(desc_varB)"
	@echo "-- 变量 ------------------------------------------------------"
	@echo "  VARIANT=$(VARIANT)  TAG=$(TAG)  SEED=$(SEED)  CLOCK=$(CLOCK)  CFG=$(CFGTAG)  PVT=$(PVT)"

check:
	@test -f $(FLIST) || { echo "✗ 缺少 filelist: $(FLIST)"; exit 1; }
	@test -n "$(TOP)" || { echo "✗ config/variants.mk 里没有 top_$(VARIANT)"; exit 1; }
	@mkdir -p $(RUN)

# ---------------- 0. 数值模型（黄金模型，不依赖任何 EDA 工具）------------
# 顺序铁律：先模型后 RTL。模型跑不通，RTL 只是在翻译一个错误。
model:
	$(MAKE) -C model

modeltest: model
	$(MAKE) -C model test

err: model
	$(MAKE) -C model err SEED=$(SEED)

# ---------------- 1. 测试向量（黄金模型直接导出，种子必须记录）----------------
# 铁律：向量只能由 model/ 里的 C 模型产出。任何"另写一份生成器"的做法，
#       都会让"逐位一致"这件事变成两份代码互相对答案，验证就失去意义。
#
# 每个方案按自己的数值格式导出：qkv/ref 与格式无关（只与 seed 有关，共享），
# 黄金输出 exp 带格式标签，所以 ref(16bit) 与 varA(10bit) 不会互相覆盖。
vec:
	bash flow/sim/genvec.sh $(SEED) $(MODE)

# 回读校验：不重新生成，只把磁盘上的向量读回来与模型重算的结果逐值比对。
# 专抓两类事故：改了模型忘了 make vec（向量过期）、文件被截断/手工改过。
# 按「数值格式」去重而不是按方案：varA 与 varB 都是 10/7，校验内容完全相同，
# 逐个方案跑等于把同一件事做两遍（还要多编译两次模型）。
vecfsck:
	@seen=""; \
	for v in $(VARIANTS); do \
	  cfg=$$( $(MAKE) -s --no-print-directory cfgof VARIANT=$$v ); \
	  case " $$seen " in *" $$cfg "*) continue;; esac; \
	  seen="$$seen $$cfg"; \
	  echo "-- $$v -> $$cfg"; \
	  $(MAKE) --no-print-directory vecfsck1 VARIANT=$$v || exit 1; \
	done

# 打印某方案的数值格式标签（供脚本拼接，不写文件）
cfgof:
	@echo $(CFGTAG)

vecfsck1:
	bash flow/sim/genvec.sh $(SEED) $(MODE) check

# 流程自检：不需要任何 RTL，验证 tb / 驱动 / 判据 / 退出码这条链路
flowtest:
	bash flow/sim/flowtest.sh $(SEED)

# ---------------- 1.5 单元验证（四个数值件，穷举对拍）----------------
# 与系统级仿真是互补关系，不是替代：
#   单元级回答"这个数值件单独看对不对"，用穷举覆盖输入空间；
#   系统级回答"连起来跑整道题对不对"，用六类激励 + 双判据。
# 只有系统级证据的话，一个失配要沿着 QK→softmax→PV 一路二分才能定位。
unit:
	bash flow/sim/unit.sh $(VARIANT) unit-$(VARIANT)

# 所有方案各跑一遍（验证 QB/QF/LUT 参数化在 10bit 工作点上也没问题）
unitall:
	@for v in $(VARIANTS); do \
	  $(MAKE) --no-print-directory unit VARIANT=$$v || exit 1; \
	done

# ---------------- 2. 仿真（VCS）----------------
# 一次只跑一类激励。要跑全部六类用 make regress。
sim: check
	bash flow/sim/build.sh $(VARIANT) $(TAG) $(CLOCK)
	bash flow/sim/run.sh $(VARIANT) $(TAG) $(CAT) $(N) $(SEED) $(VERBOSE)
	@$(MAKE) --no-print-directory manifest

# 六类激励全跑。MODE=smoke 日常用，MODE=full 出报告数据用。
regress: check
	bash flow/sim/regress.sh $(VARIANT) $(TAG) $(SEED) $(MODE) $(CLOCK)
	@$(MAKE) --no-print-directory manifest

lint: check
	@if command -v verilator >/dev/null; then \
	  verilator --lint-only -Wall --top-module $(TOP) -f $(FLIST); \
	else echo "· 未装 verilator，跳过 lint（VCS 编译本身就是最严的语法闸门）"; fi

# ---------------- 3. 综合 / 功耗 ----------------
# 为什么功耗不单独跑一次：VM 上只装了 Genus，没装 PrimeTime/PowerArtist。
# 单独的功耗工具不存在时硬造一个"power 目标"只会产出假数据；
# 功耗就在同一次综合里一并报告（set_switching_activity + report_power），
# 这样面积/时序/功耗出自同一次映射结果，三者天然自洽。
syn: check pdkcheck
	bash flow/synth/run_syn.sh $(VARIANT) $(RUN) $(CLOCK) $(PVT)
	@$(MAKE) --no-print-directory manifest

# 只看已跑过的那次综合的功耗数字与假设，不重新综合
power: check
	@test -f $(RUN)/syn/power.rpt || { \
	  echo "✗ $(RUN)/syn/power.rpt 不存在 —— 先 make syn VARIANT=$(VARIANT) TAG=$(TAG)"; exit 1; }
	@echo "== 功耗（来自 $(RUN)/syn/power.rpt，与面积时序同一次综合）=="
	@grep -iE "total power|leakage|switching|internal" $(RUN)/syn/power.rpt | head -12
	@echo "== 活动率假设 =="
	@echo "  toggle_rate=$(SYN_TOGGLE_RATE)  static_probability=$(SYN_STATIC_PROB)"
	@echo "  （改这两项必须重跑 syn，否则 mW 与前一次不可比）"

# 综合前的工具/库自检：库路径、工艺角、约束参数是否齐全且自洽
pdkcheck:
	@echo "== PDK =="
	@echo "  PDK      : $(PDK)"
	@echo "  CORNER   : $(CORNER)   PVT: $(PVT)"
	@echo "  时序库   : $(SYN_LIB)"
	@echo "  LEF      : $(SYN_LEF)"
	@echo "  驱动单元 : $(SYN_DRIVE_CELL)   负载: $(SYN_LOAD_PF) pF"
	@echo "  不确定度 : $(SYN_CLK_UNCERT_PCT)% 周期   I/O 延迟: $(SYN_IO_DELAY_PCT)% 周期"
	@test -n "$(SYN_LIB)" || { echo "✗ SYN_LIB 为空 —— config/pdk.mk 里没有 lib_$(CORNER)_$(PDK)"; exit 1; }
	@test -n "$(SYN_LEF)" || { echo "✗ SYN_LEF 为空 —— config/pdk.mk 里没有 lef_$(PDK)"; exit 1; }

# 三个角都综合一遍（签核用：tt 看典型、ss 看 setup、ff 看短路功耗）
synall:
	@for c in tt ss ff; do \
	  echo "======== corner $$c ========"; \
	  $(MAKE) --no-print-directory syn VARIANT=$(VARIANT) TAG=$(TAG)-$$c CORNER=$$c || exit 1; \
	done

# ---------------- 4. 结果汇总（复现分的关键）----------------
collect:
	$(PY) flow/collect/collect.py runs/ results/metrics.csv

table:
	$(PY) flow/collect/make_table.py results/metrics.csv > results/tables.md
	@echo "-> results/tables.md"

# ---------------- 5. 可复现清单 ----------------
manifest: check
	@{ \
	  echo "variant  : $(VARIANT)"; \
	  echo "desc     : $(desc_$(VARIANT))"; \
	  echo "top      : $(TOP)"; \
	  echo "tag      : $(TAG)"; \
	  echo "seed     : $(SEED)"; \
	  echo "clock    : $(CLOCK) MHz"; \
	  echo "pvt      : $(PVT)"; \
	  echo "sim      : $(SIM)"; \
	  echo "syn      : $(SYN)"; \
	  echo "commit   : $$(git rev-parse --short HEAD 2>/dev/null || echo 'NOT-A-REPO')"; \
	  echo "dirty    : $$(git status --porcelain 2>/dev/null | wc -l) 个文件未提交"; \
	  echo "host     : $$(hostname)"; \
	  echo "time     : $$(date -Iseconds)"; \
	} > $(RUN)/INFO.txt
	@echo "-> $(RUN)/INFO.txt"
	@test "$$(git status --porcelain 2>/dev/null | wc -l)" -eq 0 || \
	  echo "⚠ 工作区有未提交改动 —— 这次结果绑不到某个 commit，别急着写进报告"

# ---------------- 6. 提交前自检（docs/engineering/01 §9）----------------
# 目的只有一个：确认仓库没有自相矛盾。任何一项红了都别提交。
# 刻意不检查"代码写得好不好"——那是 review 的事，机器管不了。
#
# 逻辑放在 flow/preflight.sh 而不是内联在配方里：这段有十几个 shell 变量
# 与引号嵌套，内联在 make 里一处引号错就只报 "unexpected EOF"，查起来极慢。
preflight:
	bash flow/preflight.sh

clean:
	rm -rf runs/*/simv runs/*/simv.daidir runs/*/csrc runs/*/*.vcd runs/*/*.fsdb
