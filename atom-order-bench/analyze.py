#!/usr/bin/env python3
"""Summarise interleaved benchmark runs: variant/base ratios paired per run.

  analyze.py micro.csv      rows: variant,run,set,bench,ns_per_op
  analyze.py compile.csv    rows: variant,run,bench,ms[,extra]
"""
import csv, sys, statistics
from collections import defaultdict

path = sys.argv[1]
data = defaultdict(dict)  # (set, bench) -> {(variant, run): value}
for row in csv.reader(open(path)):
    if len(row) >= 5 and path.endswith("micro.csv"):
        v, run, s, b, x = row[:5]
    else:
        v, run, b, x = row[:4]
        s = "-"
    data[(s, b)][(v, run)] = float(x)

VARIANTS = [v for v in ("base", "name", "hash", "hash1")
            if any(v == k[0] for d in data.values() for k in d)]
OTHERS = VARIANTS[1:]
print(f"{'set':7} {'bench':18} " + " ".join(f"{v:>10}" for v in VARIANTS) + "   "
      + "   ".join(f"{v + '/base':>18}" for v in OTHERS))
for (s, b), vals in data.items():
    runs = sorted({r for (_, r) in vals})
    med = {v: statistics.median(vals[(v, r)] for r in runs if (v, r) in vals)
           for v in VARIANTS}
    cols = []
    for v in OTHERS:
        ratios = [vals[(v, r)] / vals[("base", r)] for r in runs
                  if (v, r) in vals and ("base", r) in vals]
        m = statistics.median(ratios)
        cols.append(f"{(m - 1) * 100:+6.1f}% [{(min(ratios) - 1) * 100:+.0f},{(max(ratios) - 1) * 100:+.0f}]")
    print(f"{s:7} {b:18} " + " ".join(f"{med[v]:10.1f}" for v in VARIANTS) + "   "
          + "   ".join(f"{c:>18}" for c in cols))
