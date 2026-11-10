#!/usr/bin/env python3
"""Summarise run_matrix.sh logs: median over rounds, candidate versus baseline.

    summarize.py BASE CAND matrix.log [more.log ...]

For each configuration and thread count it prints QPS, P50 and P99 change and the recall
difference, then the scaling efficiency at the highest thread count
(QPS(N) / (N * QPS(1))). A QPS gain of 15% or more is marked with "*".
"""
import re
import statistics
import sys
from collections import defaultdict

LINE = re.compile(
    r"^r(?P<round>\d+)\s+(?P<variant>\S+)\s+(?P<config>\S+)\s+ef=\s*(?P<ef>\d+)\s+th=\s*(?P<th>\d+)"
    r"\s+\S+\s+qps=(?P<qps>[\d.]+)\s+p50=(?P<p50>[\d.e+-]+)\s+p99=(?P<p99>[\d.e+-]+)"
    r"\s+recall=(?P<recall>[\d.e+-]+)"
)


def load(paths):
    runs = defaultdict(list)  # (variant, config, ef, th) -> [(qps, p50, p99, recall, round)]
    count = 0
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = LINE.match(line.strip())
                if not m:
                    continue
                key = (m["variant"], m["config"], int(m["ef"]), int(m["th"]))
                runs[key].append(tuple(float(m[k]) for k in ("qps", "p50", "p99", "recall"))
                                 + (int(m["round"]),))
                count += 1
    return runs, count


def median(values, i):
    return statistics.median(v[i] for v in values)


def pct(new, old):
    return (new / old - 1.0) * 100.0


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    base, cand, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
    runs, count = load(paths)
    print(f"runs {count}")
    configs = sorted({(k[1], k[2]) for k in runs if k[0] == base}, key=lambda c: c[0])
    for config, ef in configs:
        threads = sorted(k[3] for k in runs if k[:3] == (base, config, ef) and (cand, config, ef, k[3]) in runs)
        if not threads:
            continue
        b0 = runs[(base, config, ef, threads[0])]
        rounds = len({v[4] for v in b0})
        print(f"== {config} ef={ef} rounds={rounds} recall={median(b0, 3):.4f}")
        qps = {}
        for th in threads:
            b, c = runs[(base, config, ef, th)], runs[(cand, config, ef, th)]
            bq, cq = median(b, 0), median(c, 0)
            qps[th] = (bq, cq)
            gain = pct(cq, bq)
            print(f"  th{th:2d} QPS {bq:8.0f} -> {cq:8.0f} {gain:+6.1f}%{'*' if gain >= 15 else ' '}"
                  f" P50 {pct(median(c, 1), median(b, 1)):+6.1f}%"
                  f"  P99 {median(b, 2):.3f}->{median(c, 2):.3f} {pct(median(c, 2), median(b, 2)):+6.1f}%"
                  f"  dRecall {median(c, 3) - median(b, 3):+.5f}")
        lo, hi = threads[0], threads[-1]
        if lo == 1 and hi > 1:
            eff = lambda i: qps[hi][i] / (hi * qps[lo][i])  # noqa: E731
            print(f"  scaling eff {hi}: base {eff(0):.3f} final {eff(1):.3f}")


if __name__ == "__main__":
    main()
