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
SIM     ?= iverilog
SYN     ?= yosys
PY      ?= python

RUN     := runs/$(TAG)
FLIST   := rtl/$(VARIANT)/filelist.f
TOP     := $(top_$(VARIANT))
CLOCK   := $(clock_$(VARIANT))
VECDIR  := tb/vectors/$(SEED)

export VARIANT TAG SEED RUN FLIST TOP CLOCK PVT

.PHONY: all help check vec sim lint syn power collect table manifest clean

# 说明：这里刻意不用 shell 循环做变量间接引用——
#       某些 Windows 环境下长命令行里的非 ASCII 会被截断，导致引号失配。
#       值仍然从 config/variants.mk 取，新增方案时在这里补一行即可。

help:
	@echo "-- targets ----------------------------------------------------"
	@echo "  make vec     SEED=...                生成测试向量 + 记录种子"
	@echo "  make sim     VARIANT=<v> TAG=<t>     编译并跑自检测试平台"
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

# ---------------- 1. 测试向量（黄金模型生成，种子必须记录）----------------
vec: check
	@mkdir -p $(VECDIR)
	$(PY) model/gen_vectors.py --seed $(SEED) --out $(VECDIR)
	@printf "seed=%s\ngenerated=%s\nmodel=model/fp16_attn.py\n" $(SEED) "$$(date -Iseconds)" > $(VECDIR)/meta.txt
	@echo "→ 向量写入 $(VECDIR)（该目录必须进版本库）"

# ---------------- 2. 仿真 ----------------
sim: check
ifeq ($(SIM),iverilog)
	iverilog -g2012 -Wall -o $(RUN)/simv -s tb_$(TOP) -f $(FLIST) tb/sys/tb_$(TOP).sv \
	  && vvp $(RUN)/simv +VECDIR=$(VECDIR)
else ifeq ($(SIM),vcs)
	vcs -full64 -sverilog -timescale=1ns/1ps -o $(RUN)/simv -f $(FLIST) tb/sys/tb_$(TOP).sv \
	  && $(RUN)/simv +VECDIR=$(VECDIR)
else ifeq ($(SIM),xrun)
	xrun -sv -f $(FLIST) tb/sys/tb_$(TOP).sv +VECDIR=$(VECDIR) -l $(RUN)/sim.log
else ifeq ($(SIM),vsim)
	vlog -sv -f $(FLIST) tb/sys/tb_$(TOP).sv && vsim -c tb_$(TOP) -do "run -all; quit" -l $(RUN)/sim.log
else
	$(error SIM 只支持 iverilog / vcs / xrun / vsim)
endif
	@$(MAKE) --no-print-directory manifest

lint: check
	@if command -v verilator >/dev/null; then \
	  verilator --lint-only -Wall --top-module $(TOP) -f $(FLIST); \
	else echo "· 未装 verilator，跳过 lint"; fi

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
