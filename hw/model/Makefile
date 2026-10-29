# =====================================================================
#  hw/model/Makefile —— 模型层（不依赖任何 EDA 工具）
#
#  用法：
#    make                编译两个可执行
#    make test           跑单元自检（fp16 / 定点 / exp2 / 端点）
#    make err            跑误差基线，结果写 ../results/error_baseline.txt
#    make err SEED=...   换种子
#    make allrun         test + err
#    make clean
# =====================================================================
CC      ?= gcc
ifeq ($(origin CC),default)
CC := gcc
endif

CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -Wno-unused-parameter
LDLIBS  ?= -lm
SEED    ?= 20260101

BIN     := attn_baseline
TBIN    := attn_selftest

MODEL_SRCS := attn_model.c
HDRS       := attn_model.h vecgen.h fx.h fp16.h

OUT     := ../results/error_baseline.txt

.PHONY: all test err allrun clean

all: $(BIN) $(TBIN)

$(BIN): main.c vecgen.c $(MODEL_SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ main.c vecgen.c $(MODEL_SRCS) $(LDLIBS)

$(TBIN): selftest.c $(MODEL_SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ selftest.c $(MODEL_SRCS) $(LDLIBS)

test: $(TBIN)
	./$(TBIN)

err: $(BIN)
	@mkdir -p ../results
	./$(BIN) $(SEED) $(OUT) || true
	@echo "→ $(OUT)"

allrun: test err

clean:
	rm -f $(BIN) $(TBIN) $(BIN).exe $(TBIN).exe
