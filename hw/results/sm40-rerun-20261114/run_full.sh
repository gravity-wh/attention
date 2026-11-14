#!/bin/bash
# Drive a clean full-mode run of all three variants at commit a0e713a.
set -uo pipefail
cd /root/work/hw || exit 1
echo "a0e713a6fc837a78c5abccc320800165900a0c74" > .commit
STAMP=$(date +%m%d_%H%M)
mkdir -p runs/_archive

echo "==================== $(date '+%F %T') start ===================="
echo "commit file : $(cat .commit)"
md5sum tb/sys/tb_attn.sv flow/collect/collect.py flow/sim/run.sh Makefile

for v in ref varA varB; do
    if [ -d "runs/$v-sm40-tt" ]; then
        mv "runs/$v-sm40-tt" "runs/_archive/$v-sm40-tt-old-$STAMP"
        echo "[archive] runs/$v-sm40-tt -> runs/_archive/$v-sm40-tt-old-$STAMP"
    fi
done

for v in ref varA; do
    echo "==================== vec $v full $(date '+%T') ===================="
    make vec SEED=20260101 MODE=full VARIANT=$v || { echo "VEC_FAIL_$v"; exit 1; }
done

for v in ref varA varB; do
    echo "==================== pair $v $(date '+%T') ===================="
    make pair VARIANT=$v TAG=$v-sm40-tt MODE=full SEED=20260101 CORNER=tt \
        || { echo "PAIR_FAIL_$v"; exit 1; }
done

echo "==================== collect $(date '+%T') ===================="
make collect
echo "==================== $(date '+%F %T') done ===================="
for v in ref varA varB; do
    echo "--- runs/$v-sm40-tt/summary.csv ---"
    cat runs/$v-sm40-tt/summary.csv
done
