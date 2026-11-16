#!/usr/bin/env bash
# Download the four datasets into $DATA_DIR as HDF5 files (about 15 GB in total).
#
#   prepare_data.sh [gist] [sift] [cohere] [openai]     # default: all four
#
# GIST-960 and SIFT-128 come from ann-benchmarks. Cohere-768 (1M) and OpenAI-1536 (500K) come from
# the public VectorDBBench files and are converted with convert_vdbbench.py (numpy, pyarrow, h5py).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
mkdir -p "$DATA_DIR"

ann() {
    local f=$DATA_DIR/$1.hdf5
    [ -s "$f" ] || curl -fSL -o "$f" "https://ann-benchmarks.com/$1.hdf5" || { rm -f "$f"; return 1; }
    echo "$f ready"
}

vdb() {
    local remote=$1 out=$DATA_DIR/$2.hdf5 src=$DATA_DIR/$1
    [ -s "$out" ] && { echo "$out ready"; return 0; }
    mkdir -p "$src"
    for p in shuffle_train test neighbors; do
        [ -s "$src/$p.parquet" ] || curl -fSL -o "$src/$p.parquet" \
            "https://assets.zilliz.com/benchmark/$remote/$p.parquet" || return 1
    done
    python3 "$HERE/convert_vdbbench.py" "$src" "$out" && rm -rf "$src"
}

for d in ${@:-gist sift cohere openai}; do
    case $d in
        gist) ann gist-960-euclidean ;;
        sift) ann sift-128-euclidean ;;
        cohere) vdb cohere_medium_1m cohere-768-angular ;;
        openai) vdb openai_medium_500k openai-1536-angular ;;
        *) echo "unknown dataset $d"; exit 1 ;;
    esac
done
