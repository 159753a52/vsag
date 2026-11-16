#!/usr/bin/env bash
# Compare packed and spread thread placement, to tell an L3/CCD bandwidth limit from a code issue.
#
#   placement.sh ROUNDS "CONFIGS" "THREADS" OUT_PREFIX VARIANT [VARIANT ...]
#
# packed: one logical CPU per physical core starting at CPU 0 (fills one L3 domain first);
# spread: the same number of threads spread evenly over all CPUs (all L3 domains).
# Results go to OUT_PREFIX-packed.log and OUT_PREFIX-spread.log in the run_matrix.sh format,
# so summarize.py works on each file.
# Example (the GIST SQ8 4->8 thread drop):
#   placement.sh 2 "gist-sq8 cohere-sq8 gist-rabitq" "4 8 16" cliff base final
# Check the L3 domains first: cat /sys/devices/system/cpu/cpu*/cache/index3/shared_cpu_list | sort -u
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
[ $# -ge 5 ] || { sed -n '2,13p' "$0"; exit 1; }
rounds=$1 configs=$2 threads=$3 out=$4
shift 4
for ((r = 1; r <= rounds; r++)); do
    for c in $configs; do
        for th in $threads; do
            for place in packed spread; do
                cpus=$(cpus_$place "$th")
                for v in "$@"; do
                    echo "r$r $(bash "$HERE/bench.sh" search "$v" "$c" "$th" "$cpus")" >> "$out-$place.log"
                done
            done
        done
    done
done
tail -n 4 "$out-packed.log" "$out-spread.log"
