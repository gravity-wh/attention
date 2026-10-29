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

# -ffp-contract=off 是复现性的前提，不是为了性能：
#   gcc 默认允许把 a*b+c 收缩成 FMA，收缩与否改变 double 的最后一位，
#   于是同一份源码在不同编译器/不同 -O 级别下算出不同的 float64 参考值，
#   ref.hex 就会出现无意义的 diff。定点和 FP16 路径不受影响，但参考值必须钉死。
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -Wno-unused-parameter -ffp-contract=off -fno-fast-math
LDLIBS  ?= -lm
SEED    ?= 20260101

BIN     := attn_baseline
TBIN    := attn_selftest
VECBIN  := attn_dumpvec

MODEL_SRCS := attn_model.c
HDRS       := attn_model.h vecgen.h fx.h fp16.h

OUT     := ../results/error_baseline.txt

.PHONY: all test err allrun clean vecbin

all: $(BIN) $(TBIN)

# 向量导出器：RTL 测试平台的唯一向量来源（见 flow/sim/genvec.sh）
vecbin: $(VECBIN)

$(VECBIN): dumpvec.c vecgen.c $(MODEL_SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ dumpvec.c vecgen.c $(MODEL_SRCS) $(LDLIBS)

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
	rm -f $(BIN) $(TBIN) $(VECBIN) $(BIN).exe $(TBIN).exe $(VECBIN).exe
