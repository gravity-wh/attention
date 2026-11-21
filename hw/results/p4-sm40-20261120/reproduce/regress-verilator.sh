#!/usr/bin/env bash
# Run the repository's existing system testbench using Verilator.
set -euo pipefail

variant=${1:?usage: regress-verilator.sh <ref|varA|varB> <tag>}
tag=${2:?missing run tag}
case "$variant" in
    ref) qb=16; qf=13 ;;
    varA|varB) qb=10; qf=7 ;;
    *) echo "Unknown variant: $variant" >&2; exit 2 ;;
esac
seed=20260101
cfg="qb${qb}qf${qf}"
run="runs/$tag"
vecdir="tb/vectors/s${seed}_full"
mkdir -p "$run"

if [ ! -f "$vecdir/geninfo_${cfg}.txt" ]; then
    make vec MODE=full SEED="$seed" VARIANT="$variant" > "$run/vectors.log" 2>&1
fi
verilator --version > "$run/verilator-version.txt"
verilator --binary --timing --top-module tb_attn --Mdir "$run/obj_dir" \
    -j 2 -Wno-fatal "-DDUT=top_$variant" "-DDUT_NAME=\"top_$variant\"" \
    "-DATTN_QB=$qb" "-DATTN_QF=$qf" -DATTN_LUT=4 \
    -f "rtl/$variant/filelist.f" tb/common/attn_tb_pkg.sv tb/sys/tb_attn.sv \
    > "$run/build.log" 2>&1

printf 'category,tasks,pass,fail,lat_min,lat_avg,lat_max,load,worst_rmse,worst_maxae,mismatch,status\n' \
    > "$run/summary.csv"
while read -r category tasks; do
    log="$run/sim_$category.log"
    timeout 180 "$run/obj_dir/Vtb_attn" "+VECDIR=$vecdir" "+CFG=$cfg" \
        "+CAT=$category" "+N=$tasks" > "$log" 2>&1
    awk -v count="$tasks" '
        /^\[SUMMARY\] / {
            for (i=2; i<=NF; i++) {
                split($i, field, "=")
                val[field[1]]=field[2]
            }
            print val["cat"] "," val["tasks"] "," val["pass"] "," val["fail"] "," \
                val["lat_min"] "," val["lat_avg"] "," val["lat_max"] "," val["ld"] "," \
                val["rmse"] "," val["maxae"] "," val["mism"] "," val["status"]
            passed=(val["tasks"]==count && val["pass"]==count && val["status"]=="PASS")
        }
        END {exit !passed}
    ' "$log" >> "$run/summary.csv"
done <<'CASES'
random 200
zero 4
extreme 200
cancel 200
reset 4
cont 8
CASES
cat "$run/summary.csv"
