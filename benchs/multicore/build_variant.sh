#!/usr/bin/env bash
# Create a worktree for one benchmark variant and build vsag + eval_performance in Release mode.
#
#   build_variant.sh NAME BASE_REF [COMMIT_OR_RANGE ...]
#
# The worktree is $WORK/src-NAME (detached at BASE_REF, then the listed commits are cherry-picked),
# the build is $WORK/build-NAME. eval_immutable.patch is applied to the worktree so that the
# evaluator can call SetImmutable() after loading; this edit is for benchmarking only.
# Examples:
#   build_variant.sh base a2baa8fb                  # main before antgroup/vsag#3014
#   build_variant.sh final upstream/main pr/3302 pr/3303 pr/3304
# Third-party downloads honour the usual VSAG_THIRDPARTY_<DEP> variables (see extern/).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
[ $# -ge 2 ] || { sed -n '2,13p' "$0"; exit 1; }
name=$1 base=$2
shift 2
src=$WORK/src-$name build=$WORK/build-$name
mkdir -p "$WORK/logs"

if [ ! -d "$src" ]; then
    git -C "$REPO" worktree add -q --detach "$src" "$base" || exit 1
    for c in "$@"; do
        git -C "$src" -c user.name=bench -c user.email=bench@localhost cherry-pick "$c" > /dev/null \
            || { echo "cherry-pick $c failed in $src"; exit 1; }
    done
fi
git -C "$src" apply --check "$HERE/eval_immutable.patch" 2> /dev/null && git -C "$src" apply "$HERE/eval_immutable.patch"
grep -q VSAG_EVAL_IMMUTABLE "$src/tools/eval/case/search_eval_case.cpp" || { echo "eval patch not applied"; exit 1; }
git -C "$src" log --oneline -1

start=$SECONDS
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_TESTS=OFF -DENABLE_TOOLS=ON \
    -DENABLE_CXX11_ABI=ON -DENABLE_PYBINDS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_INTEL_MKL=OFF \
    -DVSAG_USE_SYSTEM_OPENBLAS=ON -DENABLE_CCACHE=OFF -DENABLE_WERROR=OFF \
    -DNUM_BUILDING_JOBS="$BUILD_THREADS" > "$WORK/logs/build-$name-cmake.log" 2>&1 \
    || { echo "$name: cmake failed, see $WORK/logs/build-$name-cmake.log"; exit 1; }
cmake --build "$build" --parallel "$BUILD_THREADS" --target vsag eval_performance \
    > "$WORK/logs/build-$name.log" 2>&1 || { grep -m5 "error:" "$WORK/logs/build-$name.log"; exit 1; }
echo "$name built in $((SECONDS - start))s"
