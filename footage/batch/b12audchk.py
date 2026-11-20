#!/usr/bin/env python3
# Cross-check the audit census (aud_d.tsv) against the EDL: every output
# second maps to a NEW or OLD EDL row (with +/-2 s boundary grace). Rules:
#   OLD seconds: any strict-blue frame is an anomaly (2004 files have zero)
#                -> source mixup, investigate NOW.
#   NEW seconds: bl/s >= 4 anomaly (bands were excised; only speckle allowed)
#   both: vr/s (line-diff>90) >= 3 anomaly (tear class)
import sys
D = sys.argv[1] if len(sys.argv) > 1 else "."
rows = [l.split("\t") for l in open(D + "/b12edl.tsv").read().splitlines()]
bins = {}
for ln in open(D + "/aud_d.tsv"):
    s, t, b, h, v = map(int, ln.split())
    bins[s] = (t, b, h, v)
cum = 0.0
spans = []
for r in rows:
    L = float(r[3])
    spans.append((cum, cum + L, r[0]))
    cum += L
GRACE = 2.0
def cls(s):
    for a, b, k in spans:
        if a - GRACE <= s <= b + GRACE:
            if s < a or s > b:
                return k + "?"
            return k
    return None
anom = []
tN = tO = 0
for s in sorted(bins):
    t, b, h, v = bins[s]
    k = cls(s)
    if k is None or t == 0:
        continue
    if k.startswith("OLD"):
        tO += 1
        if b > 0:
            anom.append((s, k, "OLD-BLUE", b))
    elif k.startswith("NEW"):
        tN += 1
        if b >= 4:
            anom.append((s, k, "NEW-BAND", b))
    if v >= 3:
        anom.append((s, k, "TEAR", v))
print("checked: NEW=%ds OLD=%ds  anomalies=%d" % (tN, tO, len(anom)))
for s, k, kind, n in anom[:60]:
    print("  t=%5d %-14s %-9s n=%d" % (s, k, kind, n))
if len(anom) > 60:
    print("  ...", len(anom) - 60, "more")
try:
    sil = open(D + "/aud_sil.txt").read().splitlines()
    starts = [x for x in sil if "silence_start" in x]
    print("silence(>2.5s) events:", len(starts))
    for x in starts[:12]:
        print("  ", x.split("]")[-1][:60])
except FileNotFoundError:
    pass
