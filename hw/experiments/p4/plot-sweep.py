"""Plot the paired fixed-netlist frequency sweep from collect-power.py."""
import argparse
import csv

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary_csv")
    parser.add_argument("output_png")
    args = parser.parse_args()
    frequencies = [80, 100, 120, 150]
    with open(args.summary_csv, newline="", encoding="utf-8") as stream:
        results = {
            (row["variant"], int(row["frequency_mhz"])): row
            for row in csv.DictReader(stream)
            if row["sample"] == "random_0"
        }

    figure, (energy, slack) = plt.subplots(1, 2, figsize=(8.5, 3.1), layout="constrained")
    energy.set_title("Energy per task")
    energy.set_ylabel("Energy (nJ, log scale)")
    energy.set_yscale("log")
    energy.set_ylim(90, 2100)
    energy.set_yticks([100, 200, 500, 1000, 2000], ["100", "200", "500", "1,000", "2,000"])
    slack.set_title("Setup slack before placement")
    slack.set_ylabel("Setup WNS (ns)")
    slack.axhline(0, color="#68717d", linewidth=1, linestyle="--")
    for variant, color, marker, style in (
        ("ref", "#395786", "o", "-"),
        ("varB", "#16734e", "s", "--"),
    ):
        rows = [results[(variant, frequency)] for frequency in frequencies]
        energy.plot(
            frequencies, [float(row["energy_nj"]) for row in rows], color=color, marker=marker,
            linewidth=2, linestyle=style, markersize=5, label=variant,
        )
        slack.plot(
            frequencies, [float(row["preplace_setup_wns_ns"]) for row in rows], color=color,
            marker=marker, linewidth=2, linestyle=style, markersize=5,
        )
    for axis in (energy, slack):
        axis.set_xticks(frequencies)
        axis.set_xlabel("Clock frequency (MHz)")
        axis.grid(axis="y", color="#d7dde3", linewidth=0.7)
        axis.spines[["right", "top"]].set_visible(False)
    energy.legend(frameon=False, loc="center right")
    figure.savefig(args.output_png, dpi=180, facecolor="white")


if __name__ == "__main__":
    main()
