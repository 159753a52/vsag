#!/usr/bin/env bash
# Build one index, or run one search and print a single result line.
#
#   bench.sh build CONFIG
#       Builds $WORK/idx/CONFIG.index with the "base" variant. All variants search this file.
#   bench.sh search VARIANT CONFIG THREADS [CPUS] [QUERIES]
#       Searches with $WORK/build-VARIANT. CPUS defaults to one logical CPU per physical core,
#       QUERIES to QPT * THREADS. Prints: variant config ef threads qps p50 p99 recall.
#
# Environment: EF_OVERRIDE overrides the configuration's ef_search; VARIANT_ENV_DIR/<variant> is sourced
# before the search when it exists (used for benchmark-only knobs).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
mkdir -p "$WORK/idx" "$WORK/logs" "$WORK/tmp"

eval_bin() { echo "$WORK/build-$1/tools/eval/eval_performance"; }

build() {
    local name=$1
    cfg "$name" || exit 1
    local yaml=$WORK/idx/$name.yaml
    cat > "$yaml" <<YAML
global:
  num_threads_building: $BUILD_THREADS
  exporters:
    text:
      format: "table"
      to: "stdout"
$name:
  datapath: "$DATA"
  type: "build"
  index_name: "hgraph"
  create_params: '$CP'
  index_path: "$WORK/idx/$name.index"
  num_threads_building: $BUILD_THREADS
  disable_memory: true
YAML
    local start=$SECONDS
    LD_LIBRARY_PATH=$WORK/build-base/src "$(eval_bin base)" "$yaml" > "$WORK/logs/idx-$name.log" 2>&1
    echo "build $name exit=$? $((SECONDS - start))s"
}

search() {
    local v=$1 name=$2 th=$3
    cfg "$name" || exit 1
    local ef=${EF_OVERRIDE:-$EF}
    local cpus=${4:-$(cpus_packed "$th")} q=${5:-$((QPT * th))}
    local tag=$WORK/tmp/s-$v-$name-$th-$$
    cat > "$tag.yaml" <<YAML
global:
  num_threads_searching: $th
  exporters:
    raw:
      format: "json"
      to: "file://$tag.json"
run:
  datapath: "$DATA"
  type: "search"
  index_name: "hgraph"
  create_params: '$CP'
  search_params: '{"hgraph":{"ef_search":$ef}}'
  index_path: "$WORK/idx/$name.index"
  search_mode: "knn"
  topk: 10
  search_query_count: $q
  disable_memory: true
YAML
    local envf=${VARIANT_ENV_DIR:-$WORK/varenv}/$v
    [ -f "$envf" ] && source "$envf"
    # The patched evaluator calls SetImmutable() after loading (see eval_immutable.patch).
    VSAG_EVAL_IMMUTABLE=1 LD_LIBRARY_PATH=$WORK/build-$v/src taskset -c "$cpus" "$(eval_bin "$v")" \
        "$tag.yaml" > "$tag.log" 2>&1 || { echo "$v $name th=$th FAILED: $(tail -3 "$tag.log")"; return 1; }
    python3 - "$tag.json" "$v" "$name" "$ef" "$th" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = d[0] if isinstance(d, list) else d
r = r.get("run", r)
lat = r["latency_detail(ms)"]
v, name, ef, th = sys.argv[2:6]
print(f"{v:6s} {name:13s} ef={ef:>4s} th={th:>2s} imm qps={r['qps']:.0f} "
      f"p50={lat['p50']} p99={lat['p99']} recall={r['recall_avg']}")
PY
    rm -f "$tag.yaml" "$tag.json" "$tag.log"
}

cmd=${1:-}
shift || true
case $cmd in
    build) build "$@" ;;
    search) search "$@" ;;
    *) sed -n '2,12p' "$0"; exit 1 ;;
esac
