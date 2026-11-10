#!/usr/bin/env python3
"""Convert a VectorDBBench cosine dataset (parquet) into an ann-benchmarks style HDF5 file.

    convert_vdbbench.py SRC_DIR OUT.hdf5

SRC_DIR holds shuffle_train.parquet, test.parquet and neighbors.parquet as published under
https://assets.zilliz.com/benchmark/<dataset>/. Needs numpy, pyarrow and h5py.
"""
import sys

import h5py
import numpy as np
import pyarrow.parquet as pq

TOPK = 100


def load_vectors(path):
    table = pq.read_table(path)
    ids = table.column("id").to_numpy()
    emb = table.column([n for n in table.column_names if n != "id"][0]).combine_chunks()
    dim = len(emb[0])
    values = emb.values.to_numpy(zero_copy_only=False).astype(np.float32, copy=False)
    print(path, table.num_rows, "x", dim, flush=True)
    return ids, values.reshape(-1, dim)


def normalize(x):
    return x / np.maximum(np.linalg.norm(x, axis=1, keepdims=True), 1e-12)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]

    train_ids, train = load_vectors(f"{src}/shuffle_train.parquet")
    order = np.argsort(train_ids, kind="stable")
    train_ids, train = train_ids[order], train[order]
    assert np.array_equal(train_ids, np.arange(len(train_ids))), "train ids must be 0..N-1"

    test_ids, test = load_vectors(f"{src}/test.parquet")
    order = np.argsort(test_ids, kind="stable")
    test_ids, test = test_ids[order], test[order]

    gt = pq.read_table(f"{src}/neighbors.parquet")
    gt_col = [n for n in gt.column_names if n != "id"][0]
    by_query = dict(zip(gt.column("id").to_numpy().tolist(), gt.column(gt_col).to_pylist()))
    neighbors = np.array([by_query[int(q)][:TOPK] for q in test_ids], dtype=np.int32)

    # Cosine distance = 1 - cos, the convention of ann-benchmarks "angular" files.
    tn = normalize(test)
    distances = np.empty(neighbors.shape, dtype=np.float32)
    for i in range(len(test)):
        distances[i] = 1.0 - normalize(train[neighbors[i]]) @ tn[i]

    # The published ground truth must match brute force for a few queries.
    trn = normalize(train)
    for i in range(3):
        best = np.argsort(1.0 - trn @ tn[i])[:10]
        overlap = len(set(best.tolist()) & set(neighbors[i][:10].tolist()))
        print(f"query {i}: brute-force top10 overlap with ground truth = {overlap}/10", flush=True)

    with h5py.File(out, "w") as f:
        f.attrs["distance"] = "angular"
        f.create_dataset("train", data=train)
        f.create_dataset("test", data=test)
        f.create_dataset("neighbors", data=neighbors)
        f.create_dataset("distances", data=distances)
    print("wrote", out, train.shape, test.shape, neighbors.shape, flush=True)


if __name__ == "__main__":
    main()
