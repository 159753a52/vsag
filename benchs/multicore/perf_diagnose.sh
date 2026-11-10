#!/usr/bin/env bash
# Hardware counters, top-down breakdown and hot functions for one variant under load.
#
#   perf_diagnose.sh VARIANT CONFIG [THREADS] [OUT_DIR]
#
# Starts a long search on THREADS threads (default 32), waits for the search phase, then takes
# perf stat (15 s), the PipelineL1/L2 top-down metrics (10 s) and perf record (8 s) on the pinned
# CPUs. Results: OUT_DIR/VARIANT-CONFIG.{line,stat,pipeline,hot}. Needs root or
# perf_event_paranoid <= 0. The event names are for AMD Zen 4; adjust EVENTS for other CPUs.
# Memory bandwidth (lower bound, demand reads only) = ls_dmnd_fills_from_sys.dram_io_near * 64 B / 15 s.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
[ $# -ge 2 ] || { sed -n '2,11p' "$0"; exit 1; }
v=$1 c=$2 th=${3:-32} out=${4:-$WORK/perf}
mkdir -p "$out"
tag=$out/$v-$c
EVENTS=${EVENTS:-cycles,instructions,L1-dcache-load-misses,L1-dcache-loads,cache-misses,ls_l1_d_tlb_miss.all,dTLB-load-misses,ls_dmnd_fills_from_sys.dram_io_near,ls_dmnd_fills_from_sys.local_ccx,ls_alloc_mab_count}
cpus=$(cpus_packed "$th")
cfg "$c" || exit 1

# Enough queries to keep the search busy for about 1.5-2 minutes (set QUERIES to change it);
# WARMUP covers index loading.
queries=${QUERIES:-$((QPT * th * 8))}
bash "$HERE/bench.sh" search "$v" "$c" "$th" "$cpus" "$queries" > "$tag.line" 2>&1 &
pid=$!
sleep "${WARMUP:-30}"
perf stat -C "$cpus" -e "$EVENTS" -- sleep 15 > "$tag.stat" 2>&1
perf stat -C "$cpus" -M PipelineL1,PipelineL2 -- sleep 10 > "$tag.pipeline" 2>&1
perf record -C "$cpus" -F 499 -g -o "$tag.data" -- sleep 8 > /dev/null 2>&1
wait $pid
perf report -i "$tag.data" --no-children --sort symbol --stdio -g none --percent-limit 0.5 2> /dev/null \
    | grep -v '^#' | grep -v '^$' | sed -E 's/[[:space:]]+-[[:space:]]+-[[:space:]]*$//' | head -30 > "$tag.hot"
cat "$tag.line"
echo "wrote $tag.{stat,pipeline,hot}"
