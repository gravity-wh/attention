#!/usr/bin/env python3
# =====================================================================
#  flow/collect/make_table.py —— metrics.csv → 报告可用的 markdown 表
#
#  用法： python3 flow/collect/make_table.py results/metrics.csv > results/tables.md
#
#  产出两张表，直接对应题目要求的两张：
#    表 2  实现结果与综合效率对比（ref / varA / varB 成对测量）
#    表 3  单变量优化对照（同角、同约束、只改一个变量）
#
#  设计原则：**缺数据就留空，不补默认值**。
#  报告里一个空格只是"还没测"，填个 0 就是错的数。
# =====================================================================
import csv
import sys
from collections import OrderedDict

# (列标题, metrics.csv 的键, 小数位)
T2 = [
    ("TAG", "tag", None),
    ("commit", "commit", None),
    ("方案", "variant", None),
    ("内部格式", None, None),          # 由 tag/variant 侧信息补，暂留空
    ("面积 A (µm²)", "area_um2", 1),
    ("频率 (MHz)", "clk_mhz", 0),
    ("周期数", "cycles", 0),
    ("时延 D (µs)", "delay_us", 2),
    ("功率 P (mW)", "power_mw", 3),
    ("能耗 E (nJ)", "energy_nj", 3),
    ("RMSE", "rmse", 6),
    ("最大误差", "maxae", 6),
    ("A₀/A", "a0_over_a", 2),
    ("D₀/D", "d0_over_d", 2),
    ("E₀/E", "e0_over_e", 2),
    ("WNS (ns)", "wns_ns", 3),
    ("判定", "status", None),
]


def load(path):
    rows = []
    with open(path, newline="", errors="replace") as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows


def cell(row, key, nd):
    if key is None:
        return ""
    v = row.get(key, "")
    if v is None or v == "":
        return ""
    if nd is None:
        return v
    try:
        return ("%%.%df" % nd) % float(v)
    except ValueError:
        return v


def emit(rows, cols, title, note):
    out = []
    out.append("### %s" % title)
    out.append("")
    if note:
        out.append("> %s" % note)
        out.append("")
    out.append("| " + " | ".join(c[0] for c in cols) + " |")
    out.append("|" + "|".join(["---"] * len(cols)) + "|")
    for r in rows:
        out.append("| " + " | ".join(cell(r, c[1], c[2]) for c in cols) + " |")
    out.append("")
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit("用法: make_table.py <metrics.csv> [PDK]")
    rows = load(sys.argv[1])
    # 可选第二个参数：只保留该 PDK 的行。
    # 两种工艺的面积口径不同（SMIC40 的 .lib 带真实面积且不读 LEF，net 面积为 0；
    # GPDK045 必须读 LEF 才有面积），混在一张表里比值会失真，所以按工艺分开出表。
    if len(sys.argv) > 2 and sys.argv[2]:
        pdk = sys.argv[2]
        rows = [r for r in rows if (r.get("pdk") or "") == pdk]
        print("<!-- 仅显示 PDK=%s 的结果 -->" % pdk)
    if not rows:
        sys.exit("✗ metrics.csv 是空的 —— 先跑 make syn / make regress，再 make collect")

    # ---- 表 2：每个 (方案, 角) 一行 ----
    t2 = list(rows)

    # ---- 表 3：同角的 varA/varB 与 ref 之差（单变量对照）----
    ref = OrderedDict((r["pvt"], r) for r in rows
                      if r.get("variant") == "ref")
    t3 = []
    for r in rows:
        if r.get("variant") == "ref":
            continue
        b = ref.get(r.get("pvt"))
        if not b:
            continue
        t3.append(r)

    lines = []
    lines.append("# 结果表（由 make table 生成，勿手改）")
    lines.append("")
    lines.append("工艺角与约束必须逐行相同才可比；不同角的数据不要放在同一张表里比较。")
    lines.append("")
    lines += emit(t2, T2, "表 2 实现结果与综合效率对比",
                  "A₀/D₀/E₀ = ref 在**同一工艺角**下的值。空格 = 该项尚未测量，不是 0。")
    if t3:
        lines += emit(t3, T2, "表 3 单变量优化对照",
                      "与 ref 同角对比；只改一个主要变量，其余条件保持不变。")
    else:
        lines.append("### 表 3 单变量优化对照")
        lines.append("")
        lines.append("（暂无 varA/varB 的同角数据；先跑 `make syn VARIANT=varA` 与 "
                     "`make regress VARIANT=varA`）")
        lines.append("")

    print("\n".join(lines))


if __name__ == "__main__":
    main()
