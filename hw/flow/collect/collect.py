#!/usr/bin/env python3
# =====================================================================
#  flow/collect/collect.py —— 把 runs/ 下的原始结果汇总成一张表
#
#  用法： python3 flow/collect/collect.py runs/ results/metrics.csv
#
#  输入（都是别的步骤已经写好的机器可读文件，**不再重新解析日志**）：
#    runs/<TAG>/syn/metrics.csv   综合：面积/时序/功耗（key,value）
#    runs/<TAG>/summary.csv       仿真：每类一行的 周期数/RMSE/最大误差
#    runs/<TAG>/INFO.txt          清单：variant/pvt/clock/seed/commit
#
#  为什么坚持"只读结构化中间文件"：
#    报告里的每个数字都要能回答"它从哪来"。一旦这里去解析 console 日志，
#    数字就与原始产物脱钩了 —— 复现分那 10 分正是考这个。
#
#  派生量（报告表 2 要的）：
#    D 时延(µs) = 周期数 / 频率(MHz)
#    E 能耗(nJ) = 功耗(mW) × 时延(µs)      ← mW×µs = nJ，量纲正好
#    A₀/A、D₀/D、E₀/E：以 ref 为分母的相对改善
# =====================================================================
import csv
import os
import sys

# 与 EXPERIMENTS.md 表 2 的列一一对应，顺序也一致
COLS = [
    "tag", "variant", "commit", "pvt", "pdk",
    "clk_mhz", "cycles", "delay_us",
    "area_um2", "cells", "regs",
    "wns_ns", "tns_ns", "fmax_mhz",
    "power_mw", "leakage_mw", "energy_nj",
    "rmse", "maxae", "mism", "status",
    "a0_over_a", "d0_over_d", "e0_over_e",
]


def read_kv(path):
    d = {}
    if not os.path.exists(path):
        return d
    with open(path, errors="replace") as f:
        for line in f:
            if "," not in line:
                continue
            k, v = line.rstrip("\n").split(",", 1)
            d[k.strip()] = v.strip()
    return d


def read_info(path):
    d = {}
    if not os.path.exists(path):
        return d
    with open(path, errors="replace") as f:
        for line in f:
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            d[k.strip()] = v.strip()
    return d


def read_sim(path):
    """summary.csv：每类一行；汇总时取最坏值（RMSE/误差/周期数都要最坏）。"""
    if not os.path.exists(path):
        return {}
    worst = {}
    try:
        with open(path, errors="replace") as f:
            for row in csv.reader(f):
                if len(row) < 13:
                    continue
                # TAG,VARIANT,CAT,TASKS,PASS,FAIL,LMIN,LAVG,LMAX,RMSE,MAXAE,MIS,STATUS
                cat = row[2]
                try:
                    lmax = int(row[8]); rmse = float(row[9])
                    maxae = float(row[10]); mism = int(row[11])
                except ValueError:
                    continue
                if "cycles" not in worst or lmax > worst["cycles"]:
                    worst["cycles"] = lmax
                if "rmse" not in worst or rmse > worst["rmse"]:
                    worst["rmse"] = rmse
                if "maxae" not in worst or maxae > worst["maxae"]:
                    worst["maxae"] = maxae
                worst["mism"] = worst.get("mism", 0) + mism
                if row[12] != "PASS":
                    worst["status"] = "FAIL"
                else:
                    worst.setdefault("status", "PASS")
                worst.setdefault("cats", []).append(cat)
    except OSError:
        return {}

    if "cats" in worst:
        worst["cats"] = sorted(set(worst["cats"]))
    return worst


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def main():
    if len(sys.argv) < 3:
        sys.exit("用法: collect.py <runs_dir> <out_csv>")
    runs, out = sys.argv[1], sys.argv[2]

    rows = []
    if os.path.isdir(runs):
        for tag in sorted(os.listdir(runs)):
            rd = os.path.join(runs, tag)
            syn = read_kv(os.path.join(rd, "syn", "metrics.csv"))
            sim = read_sim(os.path.join(rd, "summary.csv"))
            info = read_info(os.path.join(rd, "INFO.txt"))
            if not syn and not sim:
                continue

            clk = fnum(syn.get("clk_mhz"))
            pwr = fnum(syn.get("power_mw"))
            cyc = sim.get("cycles")
            delay = (cyc / clk) if (cyc and clk) else None
            energy = (pwr * delay) if (pwr is not None and delay) else None

            rows.append({
                "tag": tag,
                "variant": info.get("variant", syn.get("variant", "?")),
                "commit": info.get("commit", "?"),
                "pvt": syn.get("pvt", info.get("pvt", "?")),
                "pdk": info.get("pdk", ""),
                "clk_mhz": clk,
                "cycles": cyc,
                "delay_us": delay,
                "area_um2": fnum(syn.get("area_um2")),
                "cells": syn.get("cells"),
                "regs": syn.get("regs"),
                "wns_ns": fnum(syn.get("wns_ns")),
                "tns_ns": fnum(syn.get("tns_ns")),
                "fmax_mhz": fnum(syn.get("fmax_mhz")),
                "power_mw": pwr,
                "leakage_mw": fnum(syn.get("leakage_mw")),
                "energy_nj": energy,
                "rmse": sim.get("rmse"),
                "maxae": sim.get("maxae"),
                "mism": sim.get("mism"),
                "status": sim.get("status", "SYN-ONLY"),
            })

    # ---- 相对改善：以 ref 那一行为分母 -------------------------------
    # 分母必须来自同一个工艺角、同一套约束。跨角比值没有意义，所以只在
    # 同 pvt 内配对；找不到同角的 ref 就留空，绝不拿别的角凑数。
    base = {}
    for r in rows:
        if r["variant"] == "ref" and r["pvt"] not in base:
            base[r["pvt"]] = r

    for r in rows:
        b = base.get(r["pvt"])
        if not b or r is b:
            r["a0_over_a"] = r["d0_over_d"] = r["e0_over_e"] = 1.0 if b else None
            continue
        r["a0_over_a"] = ratio(b["area_um2"], r["area_um2"])
        r["d0_over_d"] = ratio(b["delay_us"], r["delay_us"])
        r["e0_over_e"] = ratio(b["energy_nj"], r["energy_nj"])

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        for r in rows:
            w.writerow({k: fmt(r.get(k)) for k in COLS})

    print("[collect] %d 行 -> %s" % (len(rows), out))
    for r in rows:
        print("  %-14s %-5s A=%-9s D=%-8s E=%-8s RMSE=%-8s %s" % (
            r["tag"], r["variant"], fmt(r["area_um2"]), fmt(r["delay_us"]),
            fmt(r["energy_nj"]), fmt(r["rmse"]), r["status"]))


def ratio(a, b):
    a, b = fnum(a), fnum(b)
    if a is None or not b:
        return None
    return a / b


def fmt(x):
    if x is None or x == "":
        return ""
    if isinstance(x, str):
        return x
    return "%.6g" % x


if __name__ == "__main__":
    main()
