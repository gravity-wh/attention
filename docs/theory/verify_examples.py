#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 RTL 语义复算 03-一个例子的数值链路.html 里的每一个数字。

用法：
    python verify_examples.py          # 两个例子都跑
    python verify_examples.py micro    # 只跑 §00-§07 的 4 列微例
    python verify_examples.py full     # 只跑 §08 的 16x16 全例

原则：这里只有整数运算——RNE 右移、LUT 插值、恢复余数除法、FP16 打包，
逐条对应 attn_math.svh / exp2_unit.sv / recip_unit.sv / fix2fp16.sv。
不使用浮点，因而不存在"因为换了实现所以数字对不上"的余地。
"""

import struct
import sys

# ---------------------------------------------------------------- 常量（全部取自 ref）
QF        = 13
S_FRAC    = 16
P_FRAC    = 16
RECIP_SH  = 40
Y_FRAC    = 13
LOG2E_Q16 = 94548          # attn_math.svh：log2(e) 的 Q16
EXP_LUT_BITS = 4
FB        = 16 - EXP_LUT_BITS      # 插值余量 12 位
SH_S      = 2 * QF + 2 - S_FRAC    # = 12，/4 藏在这里
SH_P      = RECIP_SH - P_FRAC      # = 24
SH_Y      = P_FRAC + QF - Y_FRAC   # = 16

# attn_exp2_lut：2^(-k/32)，Q16，33 项（k = 0..32）
LUT = [
    65536, 64132, 62757, 61413, 60097, 58809, 57549, 56316, 55109, 53928, 52773,
    51642, 50535, 49452, 48393, 47356, 46341, 45348, 44376, 43425, 42495, 41584,
    40693, 39821, 38968, 38133, 37316, 36516, 35734, 34968, 34219, 33486, 32768,
]


def rne_shift(x, sh):
    """attn_rne_shift：算术右移 sh 位并 round-half-to-even。"""
    if sh == 0:
        return x
    if sh < 0:
        return x << (-sh)
    q = x >> sh                       # Python 的 >> 就是算术右移（向下取整）
    r = x - (q << sh)                 # 0 <= r < 2^sh
    half = 1 << (sh - 1)
    if r > half or (r == half and (q & 1)):
        q += 1
    return q


def exp2_neg(d):
    """exp2_unit：2^(-d)，d 为 F=S_FRAC 的非负数。返回 (e, 中间量字典)。"""
    t = rne_shift(d * LOG2E_Q16, S_FRAC)      # F=S_FRAC -> F=16
    n = t >> 16
    f = t & 0xFFFF
    idx = f >> FB
    rem = f & ((1 << FB) - 1)
    a = LUT[idx << 1]                          # STRIDE = 5 - EXP_LUT_BITS = 1
    b = LUT[(idx + 1) << 1]
    e2s = a + rne_shift((b - a) * rem, FB)     # b - a < 0，有符号
    e = 0 if n >= 16 else rne_shift(e2s, n)    # n >= 16 直接 flush
    return e, dict(t=t, n=n, f=f, idx=idx, rem=rem, a=a, b=b, e2s=e2s)


def recip(t_sum):
    """recip_unit：R = RNE(2^40 / T)。RTL 用恢复余数法，商与余数与 divmod 相同。"""
    num = 1 << RECIP_SH
    q, r = divmod(num, t_sum)
    if 2 * r > t_sum or (2 * r == t_sum and (q & 1)):
        q += 1
    return q, r


def f16(y):
    """fix2fp16：F=13 的整数 -> binary16。利用"非零 |y| >= 1，永在正规区"。"""
    if y == 0:
        return 0
    sign = 0 if y > 0 else 1
    a = abs(y)
    pp = a.bit_length() - 1                    # 优先编码器：最高位位置
    ex = pp - 13 + 15
    sh = pp - 10                               # 保留 11 位有效位
    if sh <= 0:
        q = a << (-sh)
    else:
        q = a >> sh
        r = a & ((1 << sh) - 1)
        half = 1 << (sh - 1)
        if r > half or (r == half and (q & 1)):
            q += 1
    if q == 2048:                              # 尾数进位到 1024 -> 指数 +1
        q, ex = 1024, ex + 1
    return (sign << 15) | (ex << 10) | (q & 0x3FF)


def f16_val(bits):
    return struct.unpack('<e', struct.pack('<H', bits))[0]


def sep(title):
    print()
    print("=" * 78)
    print(title)
    print("=" * 78)


# ------------------------------------------------------------------ §00-§07 微例
def micro():
    sep("§00-§07  微例：4 个 key、4 维（L=4, d=4）")
    q = [8192] * 4                                   # 一行 Q：4 维全 1.0
    k_rows = [8192, 4096, 0, -4096]                  # 每行 4 维取常数

    print("\n[01] Q·Kᵀ    SH_S = %d" % SH_S)
    S = []
    for j, kv in enumerate(k_rows):
        acc = sum(q[c] * kv for c in range(4))       # 16 项 -> 这里 4 项
        s = rne_shift(acc, SH_S)
        S.append(s)
        print("  k%d  acc=%12d  S=%6d  (真值 %.4f)" % (j, acc, s, s / 65536))

    print("\n[02] 减 max")
    m = max(S)
    D = [m - s for s in S]
    for j, d in enumerate(D):
        print("  k%d  d=%6d  (真值 %.2f)" % (j, d, d / 65536))

    print("\n[03] exp2")
    E, det = [], []
    for j, d in enumerate(D):
        e, info = exp2_neg(d)
        E.append(e)
        det.append(info)
        print("  k%d  t=%6d n=%d idx=%2d rem=%4d  e=%6d  (2^-d = %.6f)"
              % (j, info['t'], info['n'], info['idx'], info['rem'], e, 2.0 ** (-d / 65536)))

    print("\n[04] 行和与倒数")
    T = sum(E)
    R, rem = recip(T)
    print("  T = %d (%.6f)   R = RNE(2^%d/T) = %d   1/T = %.10f" % (T, T / 65536, RECIP_SH, R, 1.0 / T))

    print("\n[05] 归一化    SH_P = %d" % SH_P)
    P = [min(65536, rne_shift(e * R, SH_P)) for e in E]
    for j, (e, p) in enumerate(zip(E, P)):
        print("  k%d  e=%6d  e*R=%13d  p=%6d  (p/65536 = %.5f, e/T = %.5f)"
              % (j, e, e * R, p, p / 65536, e / T))
    print("  Σp = %d  (与 65536 差 %+d)" % (sum(P), sum(P) - 65536))

    print("\n[06] P·V 与输出    SH_Y = %d" % SH_Y)
    V = [8192, 4096, -4096, -8192]
    acc = sum(p * v for p, v in zip(P, V))
    y = rne_shift(acc, SH_Y)
    bits = f16(y)
    print("  acc = %d   acc/65536 = %.4f -> y = %d" % (acc, acc / 65536, y))
    print("  FP16 = 0x%04X   %.6f" % (bits, f16_val(bits)))


# ------------------------------------------------------------------ §08 全例
def full():
    sep("§08  全例：16 个 key、16 维（L=16, d=16）")
    Q = [8192] * 16                                  # 一行 Q：16 维全 1.0
    # K 第 j 行：前 j 个 -1.0，其余 0 -> 点积计数 = -j -> S = -j/4
    K = [[-8192 if c < j else 0 for c in range(16)] for j in range(16)]

    print("\n[Q·Kᵀ]  acc = -j*2^26, S = -j*16384")
    ACC = [sum(Q[c] * K[j][c] for c in range(16)) for j in range(16)]
    S = [rne_shift(a, SH_S) for a in ACC]
    print("  acc(0..3) = %s   峰值 |acc| = %d (2^30 的 %.2f%%)"
          % (ACC[:4], abs(ACC[15]), abs(ACC[15]) / 2 ** 30 * 100))

    m = max(S)
    D = [m - s for s in S]

    print("\n[softmax]   j        S        d         t   n  idx   rem        e        p")
    E, det = [], []
    for j, d in enumerate(D):
        e, info = exp2_neg(d)
        E.append(e)
        det.append(info)
    T = sum(E)
    R, rem = recip(T)
    P = [min(65536, rne_shift(e * R, SH_P)) for e in E]
    for j in range(16):
        i = det[j]
        print("        %2d %8d %8d %9d %3d %3d %5d %8d %8d"
              % (j, S[j], D[j], i['t'], i['n'], i['idx'], i['rem'], E[j], P[j]))
    print("  T = %d = %.4f x 65536  (2^20 的 %.1f%%)" % (T, T / 65536, T / 2 ** 20 * 100))
    print("  R = %d  (1/T = %.10f, R/2^40 = %.10f)" % (R, 1.0 / T, R / 2 ** RECIP_SH))
    print("  Σp = %d  (与 65536 差 %+d)" % (sum(P), sum(P) - 65536))

    print("\n[P·V]   V 第 j 列 = (k>=j ? 1.0 : 0)  ->  y = RNE(8192*Σp≫16)")
    print("         j    Σ(c>=j)p          acc     acc/65536       y     y/8192    FP16")
    for j in range(16):
        ssum = sum(P[c] for c in range(j, 16))
        acc = 8192 * ssum
        y = rne_shift(acc, SH_Y)
        bits = f16(y)
        print("        %2d %10d %12d %11.3f %7d  %.6f   0x%04X"
              % (j, ssum, acc, acc / 65536, y, y / 8192, bits))

    ties = [j for j in range(16) if (8192 * sum(P[c] for c in range(j, 16))) % 65536 == 32768]
    print("  tie 出现于 j = %s" % ties)


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("micro", "all"):
        micro()
    if what in ("full", "all"):
        full()
