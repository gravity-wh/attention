#!/usr/bin/env bash
# Derive zero-delay cell models from the mapping Liberty and capture task windows.
set -euo pipefail
top=${1:?missing design top}
freq=${2:?missing frequency in MHz}
netlist=${3:?missing mapped netlist}
liberty=${4:?missing TT Liberty}
vecdir=${5:?missing vector directory}
cfg=${6:?missing golden vector format}
out=${7:?missing output directory}
shift 7
if [ "$#" -eq 0 ]; then set -- random_0; fi
mkdir -p "$out"
this=$(cd "$(dirname "$0")"; pwd)
tb="$this/tb_power.sv"
build="${P4_SIM_BUILD_ROOT:-$out/../gate-build}/$top"
mkdir -p "$build"
build=$(cd "$build"; pwd)
sim="$build/obj/Vtb_power"
signature=$({
    printf '%s\n' "$top"
    sha256sum "$tb" "$this/gate-vcd.sh" "$netlist" "$liberty"
} | sha256sum)
if [ ! -s "$sim" ] || [ "$signature" != "$(cat "$sim.sha256" 2>/dev/null || :)" ]; then
    rm -f "$sim.sha256"
    yosys -Q -p "read_liberty -ignore_miss_func -ignore_miss_dir -ignore_miss_data_latch -ignore_buses \"$liberty\"; write_verilog -noattr \"$build/cells-functional.v\"" \
        > "$out/build.log" 2>&1
    verilator --binary --timing --trace --trace-depth 2 \
        --output-split 16000 --output-split-cfuncs 400 \
        --top-module tb_power --Mdir "$build/obj" -j "${P4_SIM_JOBS:-2}" \
        -Wno-fatal "-DDUT=$top" "$tb" "$netlist" "$build/cells-functional.v" \
        >> "$out/build.log" 2>&1
    printf '%s\n' "$signature" > "$sim.sha256"
fi
for sample in "$@"; do
    test -s "$vecdir/${sample}_qkv.hex"
    test -s "$vecdir/${sample}_exp_$cfg.hex"
    timeout 600 "$sim" "+CLK_MHZ=$freq" "+INPUT=$vecdir/${sample}_qkv.hex" \
        "+EXPECTED=$vecdir/${sample}_exp_$cfg.hex" "+VCD=$out/$sample.vcd" \
        > "$out/$sample-window.log" 2>&1
    grep '^P4_WINDOW PASS ' "$out/$sample-window.log"
    test -s "$out/$sample.vcd"
done
