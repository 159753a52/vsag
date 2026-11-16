#!/usr/bin/env bash
# Reproduce the final scaling results of the multi-core optimisation work end to end.
#
#   reproduce.sh            # data, builds, indexes, matrix, summary
#
# Compares
#   base  = a2baa8fb, upstream main before antgroup/vsag#3014
#   final = branch bench/multicore-final of github.com/159753a52/vsag: d5108431 (includes #3014)
#           + #3304 prefetch defaults + #3302 visit/heap + #3303 SQ8 batch-4 (L2 and IP)
#           + #3355 cache-line aligned blocks
# Expect several hours on a 32-core machine; every step skips work already done.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
mkdir -p "$WORK"
LOG=$WORK/matrix.log

bash "$HERE/prepare_data.sh" || exit 1

git -C "$REPO" fetch -q https://github.com/159753a52/vsag.git \
    +bench/multicore-final:refs/bench/final || exit 1
bash "$HERE/build_variant.sh" base a2baa8fb || exit 1
bash "$HERE/build_variant.sh" final refs/bench/final || exit 1

for c in $ALL_CONFIGS; do
    [ -s "$WORK/idx/$c.index" ] || bash "$HERE/bench.sh" build "$c" || exit 1
done

if [ ! -s "$LOG" ]; then
    bash "$HERE/run_matrix.sh" 3 "gist-rabitq cohere-rabitq openai-rabitq sift-rabitq sift-sq8" base final >> "$LOG"
    bash "$HERE/run_matrix.sh" 2 "gist-sq8 cohere-sq8" base final >> "$LOG"
fi
python3 "$HERE/summarize.py" base final "$LOG" | tee "$WORK/summary.txt"
