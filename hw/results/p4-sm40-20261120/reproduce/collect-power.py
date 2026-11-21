"""Extract task-window power and pre-placement STA from Innovus reports."""
import argparse
import csv
import gzip
import re
from pathlib import Path


def find(pattern, text, path):
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        raise ValueError(f"{path}: missing {pattern}")
    return match.groups()


def read(path):
    if path.suffix == ".gz":
        with gzip.open(path, "rt", encoding="utf-8", errors="replace") as stream:
            return stream.read()
    return path.read_text(encoding="utf-8", errors="replace")


def power_rows(root):
    for report in sorted(root.glob("*/mhz*/*-power.rpt")):
        variant = report.parent.parent.name
        mhz = int(report.parent.name[3:])
        sample = report.name[:-len("-power.rpt")]
        text = read(report)
        find(r"Power Units\s*=\s*1mW\b", text, report)
        find(r"Time Units\s*=\s*1e-09 secs\b", text, report)
        start, stop = map(float, find(r"Vcd Window used.*?\(\s*([\d.]+),\s*([\d.]+)\)", text, report))
        annotated, total_nets, percent = find(r"Design annotation coverage:\s*(\d+)/(\d+)\s*=\s*([\d.]+)%", text, report)
        if int(annotated) == 0 or stop <= start:
            raise ValueError(f"{report}: no annotated activity or invalid window")
        values = {}
        for item in ("Internal", "Switching", "Leakage", ""):
            label = f" {item}" if item else ""
            value, = find(rf"^Total{label} Power:\s*([0-9.eE+-]+)", text, report)
            values[item] = float(value)
        timing = list((report.parent / "timing").glob("*.summary*"))
        if len(timing) != 1:
            raise ValueError(f"{report}: expected one pre-placement setup summary")
        wns, = find(r"\|\s*WNS \(ns\):\|\s*([0-9.eE+-]+)", read(timing[0]), timing[0])
        duration_us = (stop - start) / 1000
        yield [
            variant, mhz, sample, f"{start:.3f}", f"{stop:.3f}", f"{duration_us:.6f}",
            int(annotated), int(total_nets), percent,
            f'{values["Internal"] + values["Switching"]:.8f}',
            f'{values["Leakage"]:.8f}', f'{values[""]:.8f}',
            f'{values[""] * duration_us:.6f}', wns
        ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    rows = list(power_rows(args.root))
    if not rows:
        parser.error("No Innovus power reports found.")
    with args.output.open("w", newline="", encoding="utf-8") as output:
        writer = csv.writer(output)
        writer.writerow([
            "variant", "frequency_mhz", "sample", "start_ns", "stop_ns", "duration_us",
            "annotated_nets", "design_nets", "coverage_pct", "dynamic_mw", "leakage_mw",
            "total_mw", "energy_nj", "preplace_setup_wns_ns"
        ])
        writer.writerows(rows)


if __name__ == "__main__":
    main()
