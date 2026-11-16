#!/usr/bin/env bash
# Run the concurrency scaling matrix and append one line per search to a log.
#
#   run_matrix.sh ROUNDS "CONFIGS" VARIANT [VARIANT ...] >> matrix.log
#
# For every round, configuration and thread count (THREADS, default "1 2 4 8 16 32") all variants
# search the same index. Odd rounds run the variants in the given order, even rounds in reverse,
# so warm-up and drift do not favour one side. Summarise with summarize.py.
# Example:
#   run_matrix.sh 3 "gist-rabitq cohere-rabitq openai-rabitq sift-rabitq sift-sq8" base final >> matrix.log
#   run_matrix.sh 2 "gist-sq8 cohere-sq8" base final >> matrix.log
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
[ $# -ge 3 ] || { sed -n '2,12p' "$0"; exit 1; }
rounds=$1 configs=$2
shift 2
forward=("$@") backward=()
for ((i = ${#forward[@]} - 1; i >= 0; i--)); do backward+=("${forward[$i]}"); done

for ((r = 1; r <= rounds; r++)); do
    for c in $configs; do
        for th in ${THREADS:-1 2 4 8 16 32}; do
            if ((r % 2 == 1)); then order=("${forward[@]}"); else order=("${backward[@]}"); fi
            for v in "${order[@]}"; do
                echo "r$r $(bash "$HERE/bench.sh" search "$v" "$c" "$th")"
            done
        done
    done
done
