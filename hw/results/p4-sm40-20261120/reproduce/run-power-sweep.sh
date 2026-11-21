#!/usr/bin/env bash
# One TT STA pass and several activity-power measurements on the same mapped netlist.
set -euo pipefail
variant=${1:?usage: run-power-sweep.sh <variant> <MHz> <gate directory> <report directory>}
mhz=${2:?missing frequency}
gates=$(realpath "${3:?missing gate directory}")
out=$(realpath -m "${4:?missing report directory}")
this=$(cd "$(dirname "$0")"; pwd)
pdk=${P4_PDK_ROOT:-/opt/cadence/PDK/smic40}
sc9="$pdk/sc9mc_base_rvt_c40/r1p1"
mkdir -p "$out"
test "$(cat "$gates/gate.status")" = PASS
python3 "$this/sweep_sdc.py" "$gates/../constraints.sdc" "$out/constraints.sdc" "$mhz"
export P4_OUT="$out" P4_TOP="${P4_POWER_TOP:-top_$variant}" P4_SCOPE=tb_power/dut \
    P4_NETLIST="$gates/../netlist.v" P4_SDC="$out/constraints.sdc" P4_WINDOWS="$out/windows.txt" \
    P4_TECH_LEF="$pdk/derived/smic40_tech.lef" P4_CELL_LEF="$sc9/lef/sc9mc_logic0040ll_base_rvt_c40.lef" \
    P4_LIBRARY="$sc9/lib/sc9mc_logic0040ll_base_rvt_c40_tt_typical_max_1p10v_25c.lib" \
    P4_QRC="$sc9/voltagestorm/sc9mc_logic0040ll_base_rvt_c40_tt_typical_max_1p10v_25c.cl/qrcTechFile_RCgen"
: > "$P4_WINDOWS"
for log in "$gates/"*-window.log; do
    sample=$(basename "$log" -window.log)
    read -r start stop < <(sed -nE 's/^P4_WINDOW PASS start_ns=([0-9.]+) end_ns=([0-9.]+) .*/\1 \2/p' "$log")
    printf '%s|%s|%sns|%sns\n' "$sample" "$gates/$sample.vcd" "$start" "$stop" >> "$P4_WINDOWS"
done
test -s "$P4_WINDOWS"
timeout 1800 innovus -no_gui -legacy_ui -batch -log "$out/innovus" \
    -files "$this/power-sweep.tcl" > "$out/power-analysis.log" 2>&1
grep -q '^P4_POWER DONE$' "$out/power-analysis.log"
while IFS='|' read -r sample _; do
    grep -q 'Design annotation coverage:' "$out/$sample-power.rpt"
    grep -q 'Total Power:' "$out/$sample-power.rpt"
done < "$P4_WINDOWS"
