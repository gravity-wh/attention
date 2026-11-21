"""Regenerate a constraint file from the archived recipe at one frequency."""
import re
import sys
from pathlib import Path

source, output, freq = sys.argv[1:]
frequency_mhz = float(freq)
if frequency_mhz <= 0:
    raise SystemExit("Clock frequency must be positive.")
period = 1000 / frequency_mhz
text = Path(source).read_text(encoding="utf-8")
text = re.sub(
    r"(?m)^# 目标频率.*$", f"# 目标频率 {frequency_mhz:g} MHz → 周期 {period:.6f} ns", text
)
replacements = {
    r"(?m)(^create_clock .*? -period )[\d.]+": period,
    r"(?m)(^set_clock_uncertainty )[\d.]+": period * 0.05,
    r"(?m)(^set_input_delay )[\d.]+": period * 0.25,
    r"(?m)(^set_output_delay )[\d.]+": period * 0.25,
}
for pattern, value in replacements.items():
    text, count = re.subn(pattern, lambda match: f"{match.group(1)}{value:.6f}", text)
    if count != 1:
        raise SystemExit(f"Expected one matching SDC command, found {count}: {pattern}")
Path(output).write_text(text, encoding="utf-8")
