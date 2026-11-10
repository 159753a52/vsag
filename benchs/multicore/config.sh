#!/usr/bin/env bash
# Shared settings for the multi-core scaling benchmark. Source this file; do not run it.
# Every path can be overridden from the environment.

WORK=${WORK:-$HOME/vsag-multicore}      # worktrees, builds, indexes and logs live here
DATA_DIR=${DATA_DIR:-$WORK/data}        # HDF5 files in the ann-benchmarks layout
REPO=${REPO:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}
BUILD_THREADS=${BUILD_THREADS:-$(nproc)}

# HGraph build parameters shared by every configuration.
GRAPH='"graph_type":"odescent","max_degree":32,"ef_construction":300,"alpha":1.2'
RABITQ='"base_quantization_type":"rabitq","use_reorder":true,"precise_quantization_type":"fp32","rabitq_use_fht":true'
SQ8='"base_quantization_type":"sq8","use_reorder":true,"precise_quantization_type":"fp32"'

create_params() {
    echo "{\"dim\":$1,\"dtype\":\"float32\",\"metric_type\":\"$2\",\"index_param\":{$3,$GRAPH,\"build_thread_count\":$BUILD_THREADS}}"
}

# cfg NAME sets DATA, CP (create params), EF and QPT (queries per search thread).
# ef_search is chosen so that recall@10 is about 0.90 on the baseline.
cfg() {
    case $1 in
        gist-rabitq)   DATA=$DATA_DIR/gist-960-euclidean.hdf5;  CP=$(create_params 960 l2 "$RABITQ");      EF=200; QPT=20000 ;;
        gist-sq8)      DATA=$DATA_DIR/gist-960-euclidean.hdf5;  CP=$(create_params 960 l2 "$SQ8");         EF=150; QPT=20000 ;;
        cohere-rabitq) DATA=$DATA_DIR/cohere-768-angular.hdf5;  CP=$(create_params 768 cosine "$RABITQ");  EF=45;  QPT=60000 ;;
        cohere-sq8)    DATA=$DATA_DIR/cohere-768-angular.hdf5;  CP=$(create_params 768 cosine "$SQ8");     EF=35;  QPT=60000 ;;
        openai-rabitq) DATA=$DATA_DIR/openai-1536-angular.hdf5; CP=$(create_params 1536 cosine "$RABITQ"); EF=40;  QPT=60000 ;;
        sift-rabitq)   DATA=$DATA_DIR/sift-128-euclidean.hdf5;  CP=$(create_params 128 l2 "$RABITQ");      EF=300; QPT=100000 ;;
        sift-sq8)      DATA=$DATA_DIR/sift-128-euclidean.hdf5;  CP=$(create_params 128 l2 "$SQ8");         EF=30;  QPT=100000 ;;
        *) echo "unknown configuration: $1" >&2; return 1 ;;
    esac
}

ALL_CONFIGS="gist-rabitq cohere-rabitq openai-rabitq sift-rabitq gist-sq8 cohere-sq8 sift-sq8"

# One logical CPU per physical core. Assumes SMT siblings are numbered 2k and 2k+1
# (check with `lscpu -e`); set PIN_STEP=1 on machines without SMT or with another layout.
cpus_packed() { seq -s, 0 "${PIN_STEP:-2}" $(( ${PIN_STEP:-2} * $1 - ${PIN_STEP:-2} )); }

# The same number of threads spread evenly over all logical CPUs, i.e. across L3 domains.
cpus_spread() { local step=$(( $(nproc) / $1 )); seq -s, 0 "$step" $(( step * ($1 - 1) )); }
