#!/usr/bin/env python3
# =====================================================================
#  flow/collect/merge_metrics.py —— 把 VM 上新扫出来的 metrics.csv 并进仓库那份
#
#  为什么需要它：
#    results/metrics.csv 是**结论**，进版本库；runs/ 是**现场**，可以丢。
#    VM 上的 runs/ 只会留最近几个 tag，所以在 VM 上 `make collect` 扫出来的
#    csv 天然比仓库那份短 —— 直接 scp 覆盖，会把 ff/ss/SMIC40 那些
#    "raw 目录已经删了、只剩 csv 活着"的历史行全删掉，而且删得毫无提示。
#
#  用法：
#    # 1) VM 上扫一份新的（不要直接用 make collect 覆盖仓库那份）
#    python3 flow/collect/collect.py runs/ /tmp/m_vm.csv
#    # 2) 取回 NAS 后合并
#    python3 flow/collect/merge_metrics.py --new /tmp/m_vm.csv --into results/metrics.csv
#
#  合并规则（三条，按顺序判）：
#    1. 新行按 tag 覆盖同名旧行 —— 重跑过的就是更可信的那份；
#    2. 旧行若与某新行「同方案 + 同周期数 + 同 RMSE」，说明它是同一批实测
#       留在旧命名下的半行（ref/varA/varB 之于 ref-base/varA-base），删掉，
#       否则表里会出现两行同一组数、一行有 E 一行没有；
#    3. 其余旧行原样保留。**一条都不许丢** —— 它们对应的 raw 目录已经没了。
# =====================================================================
import argparse
import csv
import sys

COLS = ["tag", "variant", "commit", "pvt", "pdk", "clk_mhz", "cycles", "delay_us",
        "area_um2", "cells", "regs", "wns_ns", "tns_ns", "fmax_mhz",
        "power_mw", "leakage_mw", "energy_nj", "rmse", "maxae", "mism",
        "status", "a0_over_a", "d0_over_d", "e0_over_e"]


def load(path):
    with open(path, newline="", errors="replace") as f:
        return [r for r in csv.DictReader(f)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--new", required=True, help="VM 上新扫出来的 csv")
    ap.add_argument("--into", required=True, help="仓库里的 results/metrics.csv（原地更新）")
    ap.add_argument("--dry-run", action="store_true", help="只打印，不写文件")
    a = ap.parse_args()

    old, new = load(a.into), load(a.new)
    new_tags = {r["tag"] for r in new}
    sig = {(r["variant"], r["cycles"], r["rmse"]) for r in new
           if r["cycles"] and r["rmse"]}

    kept, dropped = [], []
    for r in old:
        if r["tag"] in new_tags:
            dropped.append((r["tag"], "被新行覆盖"))
            continue
        if r["cycles"] and r["rmse"] and (r["variant"], r["cycles"], r["rmse"]) in sig:
            dropped.append((r["tag"], "与新行同源（半行）"))
            continue
        kept.append(r)

    rows = sorted(kept + new, key=lambda r: (r["variant"], r["tag"]))
    print("[merge] 旧 %d + 新 %d → %d 行" % (len(old), len(new), len(rows)))
    for t, why in dropped:
        print("  丢旧行 %-14s（%s）" % (t, why))

    if a.dry_run:
        return
    with open(a.into, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in COLS})
    print("-> %s" % a.into)


if __name__ == "__main__":
    sys.exit(main())
