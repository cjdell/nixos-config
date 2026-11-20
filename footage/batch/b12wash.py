#!/usr/bin/env python3
"""Full-frame wash detector over per-segment frame-mean files (b12means2.sh output).

Wash dropouts saturate frame MEANS (u~193 v~118 y~48) even when the strict
U-V>80 census misses them (they sit at U-V~75), while pixel-mask relaxations
false-fire on natural sky. Means + run-length is the reliable detector.

usage: b12wash.py EDL.tsv SEGMMEANS_DIR
  EDL.tsv: cls src from len o0 o1 bl   (row i == segmeans/wseg<i>.tsv)
  segmeans tsv lines: t yavg uavg vavg
Prints BLUE/WHITE wash runs (>=6 consecutive flagged frames) with row owners.
"""
import sys

def main():
    edl, d = sys.argv[1], sys.argv[2]
    rows = [l.split('\t') for l in open(edl).read().splitlines()]
    G = []
    acc = 0.0
    for i, r in enumerate(rows, 1):
        try:
            fr = [list(map(float, l.split())) for l in open(f"{d}/wseg{i}.tsv")]
        except FileNotFoundError:
            print(f"NO MEANS row {i}", file=sys.stderr)
            continue
        for t, y, u, v in fr:
            G.append((acc + t, y, u, v, i))
        acc += float(r[3])
    def blue(y, u, v):  return u > 165 and (u - v) > 45 and y < 150
    def white(y, u, v): return y > 228 and abs(u - v) < 18
    found = 0
    for flag, name in ((blue, "BLUE"), (white, "WHITE")):
        cur = None
        for idx, (t, y, u, v, ri) in enumerate(G):
            if flag(y, u, v):
                if cur is None: cur = [idx, idx]
                cur[1] = idx
            else:
                if cur is not None and idx - cur[0] >= 6:
                    found += 1
                    ri = G[cur[0]][4]; r = rows[ri - 1]
                    print(f"{name} out {G[cur[0]][0]:.1f}-{G[cur[1]][0]:.1f} row{ri:02d} {r[0]} {r[1]} {r[2]}")
                cur = None
        if cur is not None and len(G) - cur[0] >= 6:
            found += 1; ri = G[cur[0]][4]
            print(f"{name} out {G[cur[0]][0]:.1f}-EOS row{ri:02d}")
    print(f"frames {len(G)} dur {acc:.1f} wash runs: {found}")

main()
