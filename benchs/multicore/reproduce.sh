#!/usr/bin/env bash
# Reproduce the final scaling results of the multi-core optimisation work end to end.
#
#   reproduce.sh            # data, builds, indexes, matrix, summary
#
# Compares
#   base  = a2baa8fb, upstream main before antgroup/vsag#3014
#   final = d5108431 (includes #3014) + #3304 prefetch default + #3302 visit/heap + #3303 SQ8 batch-4
# using the commits that were measured (before the review follow-ups, which do not change the
# search path). Expect several hours on a 32-core machine; every step skips work already done.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
mkdir -p "$WORK"
LOG=$WORK/matrix.log

bash "$HERE/prepare_data.sh" || exit 1

git -C "$REPO" fetch -q https://github.com/antgroup/vsag.git \
    +pull/3302/head:refs/bench/pr3302 +pull/3303/head:refs/bench/pr3303 +pull/3304/head:refs/bench/pr3304 \
    || exit 1
bash "$HERE/build_variant.sh" base a2baa8fb || exit 1
bash "$HERE/build_variant.sh" final d5108431 136b783e 18dc9179 175a922a 54c268e9 || exit 1

for c in $ALL_CONFIGS; do
    [ -s "$WORK/idx/$c.index" ] || bash "$HERE/bench.sh" build "$c" || exit 1
done

if [ ! -s "$LOG" ]; then
    bash "$HERE/run_matrix.sh" 3 "gist-rabitq cohere-rabitq openai-rabitq sift-rabitq sift-sq8" base final >> "$LOG"
    bash "$HERE/run_matrix.sh" 2 "gist-sq8 cohere-sq8" base final >> "$LOG"
fi
python3 "$HERE/summarize.py" base final "$LOG" | tee "$WORK/summary.txt"
