#!/usr/bin/env python3
# =====================================================================
#  flow/synth/parse_syn.py —— 把一次综合的原始报告收敛成一行 key,value
#
#  取值的主渠道是**报告文本**，不是 Tcl 取数接口。原因很实在：
#  Genus 15.20 上 `get_attribute [get_designs X] area`、`get_timing_paths`
#  会报 "invalid command name"，而 report_area / report_timing / report_power
#  / report_qor 的文本格式是稳定的。所以顺序是：
#      ① 报告文本（带**显式单位**，绝不靠默认单位猜）
#      ② metrics.tcl（Tcl 取到的值，只当补充）
#      ③ 都没有 → 记 MISSING，让人看见，绝不悄悄填 0
#
#  单位处理是这里最容易错的地方，实测三类报告用的单位并不统一：
#      area.rpt / qor.rpt 的面积 → µm²
#      timing.rpt / qor.rpt 的时间 → **ps**（不是 ns）
#      power.rpt 的功耗 → **nW**（不是 mW）
#  早期版本按 ns / mW 直接读，WNS=0 时碰巧对，一旦有非零 slack 就差 1000 倍。
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
    top_re = re.escape(top)

    # ---------------- 面积（µm²）----------------
    # qor.rpt 的 "Total Area (Cell+Physical+Net)" 含线网面积，最权威；
    # area.rpt 顶层行是 Instance / Cells / CellArea / NetArea / TotalArea。
    area = first_match(qor_rpt, [
        r"Total\s+Area\s*\(Cell\+Physical\+Net\)\s*[:=]?\s*([0-9.eE+-]+)",
        r"Total\s+Area\s*[:=]\s*([0-9.eE+-]+)",
    ])
    if area is not None:
        src["area"] = "qor.rpt"
    else:
        m = re.search(r"^%s\s+\d+\s+[0-9.eE+-]+\s+[0-9.eE+-]+\s+([0-9.eE+-]+)\s*$"
                      % top_re, area_rpt, re.M)
        if m:
            area = float(m.group(1))
            src["area"] = "area.rpt"
    if area is None:
        area = to_float(kv.get("design_area"))
        if area:
            src["area"] = "metrics.tcl"
    cell_area = first_match(qor_rpt, [r"^Cell\s+Area\s+([0-9.eE+-]+)"])
    net_area = first_match(qor_rpt, [r"^Net\s+Area\s+([0-9.eE+-]+)"])

    # ---------------- 时序 ----------------
    # 权威来源是 timing.rpt 的路径头：它把单位写在括号里，
    # 形如 "Path 1: MET (0 ps)" / "Path 1: VIOLATED (-123 ps)"。
    # qor.rpt 的 Period/Slack/TNS 同为 ps —— 这一点从
    # "clk 10000.0"（= 10 ns 周期）可以确认，秒对不上就是单位错了。
    wns = None
    m = re.search(r"^Path\s+1:\s*(MET|VIOLATED)\s*\(\s*([-+]?[0-9.eE+]+)\s*"
                  r"(ps|ns|fs)\s*\)", tim_rpt, re.M | re.I)
    if m:
        wns = scale_time(float(m.group(2)), m.group(3))
        if m.group(1).upper().startswith("VIOLATED") and wns > 0:
            wns = -wns
        src["wns"] = "timing.rpt"
    if wns is None:
        wns = to_float(kv.get("wns"))
        if wns is not None:
            src["wns"] = "metrics.tcl"

    tns = None
    m = re.search(r"^-{5,}[ \t]*\r?\n\s*(\S+)\s+([-+]?[0-9.eE+]+)\s+"
                  r"([-+]?[0-9.eE+]+)\s+(\d+)", qor_rpt, re.M)
    if m:
        # 表格列序：Group / Critical Path Slack / TNS / Violating Paths
        tns = scale_time(float(m.group(3)), "ps")
        src["tns"] = "qor.rpt"
        if wns is None:
            wns = scale_time(float(m.group(2)), "ps")
            src["wns"] = "qor.rpt"
    nviol = int(m.group(4)) if m else None

    # ---------------- 功耗 ----------------
    # power.rpt 是表格：Instance / Cells / Leakage / Dynamic / Total，
    # 单位写在表头 "Power(nW)" 里。用顶层那一行，别去加总子模块。
    punit = "nW"
    mu = re.search(r"Power\s*\((nW|uW|µW|mW|W)\)", pwr_rpt, re.I)
    if mu:
        punit = mu.group(1)
    m = re.search(r"^%s\s+\d+\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s*$"
                  % top_re, pwr_rpt, re.M)
    if m:
        leak_mw = scale_power(float(m.group(1)), punit)
        dyn_mw = scale_power(float(m.group(2)), punit)
        power_mw = scale_power(float(m.group(3)), punit)
        src["power"] = "power.rpt(%s)" % punit
    else:
        leak_mw = dyn_mw = power_mw = None
        mp = re.search(r"Total\s+Power\s*[:=]?\s*\(?\s*([0-9.eE+-]+)\s*\)?\s*"
                       r"(mW|uW|µW|nW|W)\b", pwr_rpt, re.I)
        if mp:
            power_mw = scale_power(float(mp.group(1)), mp.group(2))
            src["power"] = "power.rpt"
        ml = re.search(r"(?:Total\s+)?Leakage\s+Power\s*[:=]?\s*\(?\s*"
                       r"([0-9.eE+-]+)\s*\)?\s*(mW|uW|µW|nW|W)\b", pwr_rpt, re.I)
        leak_mw = scale_power(float(ml.group(1)), ml.group(2)) if ml else None

    # ---------------- 规模 ----------------
    # qor.rpt 的 Leaf Instance Count 才是叶子单元数；Tcl 的 llength
    # [get_cells -hier *] 会把 33 个层级实例也算进去（75469 vs 75436）。
    m = re.search(r"Leaf\s+Instance\s+Count\s+(\d+)", qor_rpt, re.I)
    cells = int(m.group(1)) if m else (int(to_float(kv.get("cell_count")) or 0) or None)
    if m:
        src["cells"] = "qor.rpt"
    m = re.search(r"Sequential\s+Instance\s+Count\s+(\d+)", qor_rpt, re.I)
    regs = int(m.group(1)) if m else (int(to_float(kv.get("num_regs")) or 0) or None)

    runtime_s = first_match(qor_rpt, [r"^Runtime\s+([0-9.eE+-]+)"])
    max_fanout = first_match(qor_rpt, [r"^Max\s+Fanout\s+([0-9.eE+-]+)"])

    # ---------------- 交叉校验：报告用的周期必须等于我们记的周期 --------
    # 抓的是"综合时的时钟"与"metrics 里记的 clk_mhz"不一致这一类错，
    # 它会让后面的 delay/energy 全错，且不报任何 error。
    qperiod = first_match(qor_rpt, [r"^clk\s+([0-9.eE+-]+)"])
    if qperiod is not None and abs(qperiod - (1000.0 / clk_mhz) * 1000.0) > 1.0:
        print("[syn] ⚠ qor 里的周期 %.1f ps 与记录的 %.1f MHz（%.1f ps）不符，"
              "单位或频率记错了" % (qperiod, clk_mhz, (1000.0 / clk_mhz) * 1000.0),
              file=sys.stderr)

    # ---------------- 落盘 ----------------
    row = [
        ("variant", variant),
        ("top", top),
        ("pvt", pvt),
        ("clk_mhz", fmt(clk_mhz)),
        ("clk_ns", fmt(1000.0 / clk_mhz)),
        ("area_um2", fmt(area)),
        ("cell_area_um2", fmt(cell_area)),
        ("net_area_um2", fmt(net_area)),
        ("cells", cells if cells is not None else "MISSING"),
        ("regs", regs if regs is not None else "MISSING"),
        ("wns_ns", fmt(wns)),
        ("tns_ns", fmt(tns)),
        ("nviol_paths", nviol if nviol is not None else "MISSING"),
        ("power_mw", fmt(power_mw)),
        ("dyn_mw", fmt(dyn_mw)),
        ("leakage_mw", fmt(leak_mw)),
        ("fmax_mhz", fmt(fmax(clk_mhz, wns))),
        ("max_fanout", fmt(max_fanout)),
        ("runtime_s", fmt(runtime_s)),
    ]
    path = os.path.join(out, "metrics.csv")
    with open(path, "w") as f:
        for k, v in row:
            f.write("%s,%s\n" % (k, v))

    # ---------------- 人看的总结 ----------------
    print("[syn] ------ 解析结果（来源：%s）------" %
          (", ".join("%s←%s" % (k, v) for k, v in src.items()) or "报告文本"))
    print("[syn] 面积      : %s um^2 = %.4f mm^2（单元 %s + 线网 %s）"
          % (fmt(area), (area or 0) / 1e6, fmt(cell_area), fmt(net_area)))
    print("[syn] 单元/寄存器: %s / %s" % (row[8][1], row[9][1]))
    print("[syn] WNS/TNS   : %s / %s ns  违例路径 %s  (目标周期 %s ns)"
          % (fmt(wns), fmt(tns), row[12][1], fmt(1000.0 / clk_mhz)))
    print("[syn] 功耗      : %s mW（动态 %s + 漏电 %s）"
          % (fmt(power_mw), fmt(dyn_mw), fmt(leak_mw)))
    if wns is not None and wns >= 0 and abs(wns) < 1e-9:
        print("[syn] NOTE WNS = 0：工具优化到刚好满足就停手，"
              "这不代表 100 MHz 就是上限。真实 f_max 要扫频才知道。")

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


def scale_time(x, unit):
    """报告里的时间单位随报告变：timing/qor 多用 ps，偶尔是 ns/fs。"""
    u = unit.lower()
    return {"fs": x / 1e6, "ps": x / 1000.0, "ns": x}[u]


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
