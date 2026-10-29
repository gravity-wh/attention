#!/usr/bin/env python3
# =====================================================================
#  flow/synth/parse_syn.py —— 把一次综合的原始报告收敛成一行 key,value
#
#  为什么不让 syn.tcl 直接写数：get_attribute 在不同 Genus 版本上名字不一样
#  （design 上叫 total_power 还是 total_power_consumption 都可能）。
#  报告文本反而稳定。所以取值顺序是：
#      ① metrics.tcl（Tcl 取到的权威值）
#      ② 报告文本兜底（regex）
#      ③ 都没有 → 记 MISSING，让人看见，绝不悄悄填 0
#
#  输出：<out>/metrics.csv，每行 "key,value"，供 run_syn.sh 的 fsck
#        与 flow/collect/collect.py 读取。
# =====================================================================
import os
import re
import sys

FATAL_KEYS = ("area_um2",)          # 缺了这些数，这次综合没有意义


def read_kv(path):
    d = {}
    if not os.path.exists(path):
        return d
    with open(path, errors="replace") as f:
        for line in f:
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            k, v = parts[0], parts[1].strip()
            if v.upper() != "MISSING":
                d[k] = v
    return d


def read_text(path):
    if not os.path.exists(path):
        return ""
    with open(path, errors="replace") as f:
        return f.read()


def first_match(text, patterns):
    """按顺序试每个正则，取第一个命中的数字。返回 float 或 None。"""
    for pat in patterns:
        m = re.search(pat, text, re.I | re.M)
        if m:
            try:
                return float(m.group(1))
            except (TypeError, ValueError):
                continue
    return None


def to_float(v):
    if v is None:
        return None
    try:
        return float(str(v).strip())
    except ValueError:
        return None


def main():
    if len(sys.argv) < 6:
        sys.exit("用法: parse_syn.py <out_dir> <clk_mhz> <pvt> <variant> <top>")
    out, clk_mhz, pvt, variant, top = sys.argv[1:6]
    clk_mhz = float(clk_mhz)

    kv = read_kv(os.path.join(out, "metrics.tcl"))
    area_rpt = read_text(os.path.join(out, "area.rpt"))
    tim_rpt = read_text(os.path.join(out, "timing.rpt"))
    pwr_rpt = read_text(os.path.join(out, "power.rpt"))
    qor_rpt = read_text(os.path.join(out, "qor.rpt"))

    src = {}

    # ---------------- 面积（µm²）----------------
    area = to_float(kv.get("design_area"))
    if area:
        src["area"] = "metrics.tcl"
    else:
        area = first_match(area_rpt, [
            r"^Total\s+area\s*[:=]\s*([0-9.eE+-]+)",
            r"^Total\s+Area\s*[:=]\s*([0-9.eE+-]+)",
            r"Cell\s+Area\s*[:=]\s*([0-9.eE+-]+)",
        ])
        if area:
            src["area"] = "area.rpt"

    # ---------------- 时序（ns）----------------
    wns = to_float(kv.get("wns"))
    if wns is None:
        wns = first_match(tim_rpt, [
            r"Slack\s*[:=]\s*([-+]?[0-9.]+)",
            r"slack\s*\([A-Z]+\)\s*[:=]?\s*([-+]?[0-9.]+)",
        ])
        if wns is not None:
            src["wns"] = "timing.rpt"

    tns = to_float(kv.get("tns"))
    if tns is None:
        tns = first_match(qor_rpt, [
            r"Total\s+Negative\s+Slack\s*[:=]\s*([-+]?[0-9.eE+-]+)",
            r"\bTNS\b\s*[:=]\s*([-+]?[0-9.eE+-]+)",
        ])
        if tns is not None:
            src["tns"] = "qor.rpt"

    # ---------------- 功耗（mW）----------------
    # 报告里的单位可能是 W / mW / µW，统一换成 mW 再落盘。
    power_mw = None
    mp = re.search(r"Total\s+Power\s*[:=]?\s*\(?\s*([0-9.eE+-]+)\s*\)?\s*"
                   r"(mW|uW|µW|nW|W)\b", pwr_rpt, re.I)
    if mp:
        power_mw = scale_power(float(mp.group(1)), mp.group(2))

    leak_mw = None
    ml = re.search(r"(?:Total\s+)?Leakage\s+Power\s*[:=]?\s*\(?\s*"
                   r"([0-9.eE+-]+)\s*\)?\s*(mW|uW|µW|nW|W)\b", pwr_rpt, re.I)
    if ml:
        leak_mw = scale_power(float(ml.group(1)), ml.group(2))

    # ---------------- 规模 ----------------
    cells = int(to_float(kv.get("cell_count")) or 0) or None
    if cells is None:
        m = re.search(r"^Total\s+instances\s*[:=]\s*(\d+)", area_rpt, re.I | re.M)
        cells = int(m.group(1)) if m else None

    regs = int(to_float(kv.get("num_regs")) or 0) or None

    # ---------------- 落盘 ----------------
    row = [
        ("variant", variant),
        ("top", top),
        ("pvt", pvt),
        ("clk_mhz", fmt(clk_mhz)),
        ("clk_ns", fmt(1000.0 / clk_mhz)),
        ("area_um2", fmt(area)),
        ("cells", cells if cells is not None else "MISSING"),
        ("regs", regs if regs is not None else "MISSING"),
        ("wns_ns", fmt(wns)),
        ("tns_ns", fmt(tns)),
        ("power_mw", fmt(power_mw)),
        ("leakage_mw", fmt(leak_mw)),
        ("fmax_mhz", fmt(fmax(clk_mhz, wns))),
    ]
    path = os.path.join(out, "metrics.csv")
    with open(path, "w") as f:
        for k, v in row:
            f.write("%s,%s\n" % (k, v))

    # ---------------- 人看的总结 ----------------
    print("[syn] ------ 解析结果（来源：%s）------" %
          (", ".join("%s←%s" % (k, v) for k, v in src.items()) or "报告文本"))
    print("[syn] 面积      : %s um^2%s" % (fmt(area), "" if area else "   ← 异常"))
    print("[syn] 单元/寄存器: %s / %s" % (row[6][1], row[7][1]))
    print("[syn] WNS/TNS   : %s / %s ns  (目标周期 %s ns)"
          % (fmt(wns), fmt(tns), fmt(1000.0 / clk_mhz)))
    print("[syn] 功耗      : %s mW（其中漏电 %s mW）" % (fmt(power_mw), fmt(leak_mw)))

    if wns is not None and wns < 0:
        print("[syn] ⚠ 时序未收敛：WNS = %s ns。这个频率下实现不了，"
              "要么降频，要么先优化关键路径。" % fmt(wns))

    missing = [k for k, v in row if v == "MISSING" and k in FATAL_KEYS]
    if missing:
        print("[syn] ✗ 关键指标缺失: %s" % ",".join(missing), file=sys.stderr)
        tail(area_rpt, "area.rpt")
        sys.exit(1)

    for k in ("area_um2", "wns_ns", "power_mw"):
        if dict(row)[k] == "MISSING":
            print("[syn] ⚠ %s 没取到 —— 报告里这一格空着，不要猜数字" % k,
                  file=sys.stderr)


def scale_power(x, unit):
    u = unit.lower().replace("µ", "u")
    return {"w": x * 1000.0, "mw": x, "uw": x / 1000.0, "nw": x / 1e6}[u]


def fmax(clk_mhz, wns):
    """由「目标周期 + slack」反推可跑的最高频率。

    周期 T = 1000/clk_mhz，还有 wns 的余量时，最短周期 ≈ T - wns。
    wns<0 表示这条路根本达不到目标频率，此时 fmax < clk_mhz。
    这只是**估算**：综合后的 slack 不含布线延迟，真实 fmax 要等 P&R。
    报告里必须写成"综合估计"，不能当成实测。
    """
    if wns is None:
        return None
    t = 1000.0 / clk_mhz
    if abs(t - wns) < 1e-9:
        return None
    return 1000.0 / (t - wns)


def fmt(x):
    if x is None:
        return "MISSING"
    return ("%.6g" % x)


def tail(text, name, n=30):
    lines = text.rstrip().splitlines()[-n:]
    print("[syn] ---- %s 末尾 %d 行（用于定位解析失败）----" % (name, len(lines)),
          file=sys.stderr)
    for ln in lines:
        print("  " + ln, file=sys.stderr)


if __name__ == "__main__":
    main()
