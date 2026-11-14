#!/bin/bash
# Phase 2: re-measure ld for the corner tags so the whole 3x3 set uses the
# same tb (ld measured, not hardcoded). ref/varA synthesis is reused (RTL
# byte-identical since 613ec89); varB ss/ff are re-synthesised.
set -uo pipefail
cd /root/work/hw || exit 1

for c in ss ff; do
    for v in ref varA; do
        echo "==================== regress $v $c $(date '+%T') ===================="
        rm -f runs/$v-sm40-$c/summary.csv
        make regress VARIANT=$v TAG=$v-sm40-$c MODE=full SEED=20260101 CORNER=$c \
            || { echo "REGRESS_FAIL_$v$c"; exit 1; }
    done
done

for c in ss ff; do
    echo "==================== pair varB $c $(date '+%T') ===================="
    rm -f runs/varB-sm40-$c/summary.csv
    make pair VARIANT=varB TAG=varB-sm40-$c MODE=full SEED=20260101 CORNER=$c \
        || { echo "PAIR_FAIL_varB$c"; exit 1; }
done

echo "==================== collect $(date '+%T') ===================="
make collect
echo "==================== $(date '+%F %T') done ===================="
