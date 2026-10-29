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

export VARIANT TAG SEED RUN FLIST TOP CLOCK PVT MODE CAT N VERBOSE

.PHONY: all help check model modeltest err vec sim regress flowtest lint syn power collect table manifest clean

# 说明：这里刻意不用 shell 循环做变量间接引用——
#       某些 Windows 环境下长命令行里的非 ASCII 会被截断，导致引号失配。
#       值仍然从 config/variants.mk 取，新增方案时在这里补一行即可。

help:
	@echo "-- targets ----------------------------------------------------"
	@echo "  make model                           编译数值模型（无 EDA 依赖）"
	@echo "  make modeltest                       模型单元自检（fp16/定点/exp2/端点）"
	@echo "  make err     SEED=...                误差基线 → results/error_baseline.txt"
	@echo "  make vec     SEED=... MODE=smoke|full  黄金模型导出 RTL 向量"
	@echo "  make flowtest                        自检流程本身（不需要 RTL）"
	@echo "  make sim     VARIANT=<v> CAT=<c>      编一个方案 + 跑一类激励"
	@echo "  make regress VARIANT=<v> MODE=full    一个方案跑完六类（回归）"
	@echo "  make lint    VARIANT=<v>             RTL 静态检查"
	@echo "  make syn     VARIANT=<v> TAG=<t>     ASIC 综合（面积 / 时序）"
	@echo "  make power   VARIANT=<v> TAG=<t>     功耗分析"
	@echo "  make collect                         汇总 runs/ → results/metrics.csv"
	@echo "  make table                           生成报告用 markdown 表格"
	@echo "  make manifest VARIANT=<v> TAG=<t>    写本次运行的可复现清单"
	@echo "  make clean                           清掉运行产物（保留 runs/ 里的报告）"
	@echo "-- variants ---------------------------------------------------"
	@echo "  ref    $(top_ref)     $(strip $(clock_ref)) MHz   $(desc_ref)"
	@echo "  varA   $(top_varA)    $(strip $(clock_varA)) MHz   $(desc_varA)"
	@echo "  varB   $(top_varB)    $(strip $(clock_varB)) MHz   $(desc_varB)"
	@echo "-- 变量 ------------------------------------------------------"
	@echo "  VARIANT=$(VARIANT)  TAG=$(TAG)  SEED=$(SEED)  CLOCK=$(CLOCK)  PVT=$(PVT)"

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
vec:
	bash flow/sim/genvec.sh $(SEED) $(MODE)

# 流程自检：不需要任何 RTL，验证 tb / 驱动 / 判据 / 退出码这条链路
flowtest:
	bash flow/sim/flowtest.sh $(SEED)

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
syn: check
	@test -x flow/synth/run_syn.sh || { echo "✗ flow/synth/run_syn.sh 未就绪"; exit 1; }
	flow/synth/run_syn.sh $(VARIANT) $(RUN) $(CLOCK) $(PVT)
	@$(MAKE) --no-print-directory manifest

power: check
	@test -x flow/power/run_power.sh || { echo "✗ flow/power/run_power.sh 未就绪"; exit 1; }
	flow/power/run_power.sh $(VARIANT) $(RUN) $(PVT)
	@$(MAKE) --no-print-directory manifest

# ---------------- 4. 结果汇总（复现分的关键）----------------
collect:
	$(PY) flow/collect/collect.py runs/ results/metrics.csv

table:
	$(PY) flow/collect/make_table.py results/metrics.csv > results/tables.md
	@echo "→ results/tables.md"

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
	@echo "→ $(RUN)/INFO.txt"
	@test "$$(git status --porcelain 2>/dev/null | wc -l)" -eq 0 || \
	  echo "⚠ 工作区有未提交改动 —— 这次结果绑不到某个 commit，别急着写进报告"

clean:
	rm -rf runs/*/simv runs/*/simv.daidir runs/*/csrc runs/*/*.vcd runs/*/*.fsdb
