#!/usr/bin/env python3
# Dell 12 alignment v2: per-block top-K global NCC peaks, then best-weight
# CHAINS of consecutive blocks with delta-old ~= +40 s (real-time passes).
# The 2026 operator scrubbed the deck: a part is passes separated by seeks,
# which is exactly a union of such chains. Outliers (wrong-peak singletons)
# die because they cannot form chains.
# Usage: b12dp.py B12AUD_DIR OUTJSON
# OUTJSON: {part: [[old_t0, old_t1, minsc, nblocks], ...]}
import numpy as np, sys, os, json, glob

SR, HOP, BLK, DEC = 2000.0, 100, 800, 8
V = SR / HOP                     # 20 vectors/s
def env16(x):
    n = len(x) // HOP
    e = np.abs(x[:n * HOP].astype(np.float32)).reshape(n, HOP).mean(axis=1)
    e = np.log1p(e); sd = e.std()
    if sd > 1e-6: e = np.clip((e - e.mean()) / sd, -4, 4)
    return (e - e.mean()).astype(np.float32)
def envf(p): return env16(np.fromfile(p, dtype=np.int16))
def dec(e, d):
    n = len(e) // d
    return e[:n * d].reshape(n, d).mean(axis=1)
def rollnorms(e, blk):
    c1 = np.concatenate([[0.0], np.cumsum(e)]); c2 = np.concatenate([[0.0], np.cumsum(e * e)])
    mu = (c1[blk:] - c1[:-blk]) / blk
    return np.sqrt(np.maximum(c2[blk:] - c2[:-blk] - blk * mu * mu, 1e-9)).astype(np.float32)

def peaks(b, e, eC, nC, norms, thr=0.38, kmax=8, sep=1200):
    bb = b - b.mean(); nbb = float(np.linalg.norm(bb))
    if nbb < 1e-3:
        return []
    bd = dec(b, DEC); bd = bd - bd.mean()
    c = np.correlate(eC, bd, "valid")
    sc = c / (nC[:len(c)] * np.linalg.norm(bd) + 1e-9)
    cand = []
    for k in np.argsort(sc)[::-1]:
        v = float(sc[k])
        if v < thr or len(cand) >= kmax:
            break
        if all(abs(int(k) - j) > sep // DEC for j in cand):
            cand.append(int(k))
    out = []
    for kc in cand:
        lo = max(0, kc * DEC - 60); hi = min(len(norms) - 1, kc * DEC + 60)
        cf = np.correlate(e[lo:hi + len(b)], bb, "valid")
        sf = cf / (norms[lo:hi + 1] * nbb + 1e-9)
        k = int(np.argmax(sf))
        out.append((lo + k, float(sf[k])))
    out.sort()
    merged = []
    for o, s in out:
        if merged and o - merged[-1][0] <= 20 * V:
            if s > merged[-1][1]:
                merged[-1] = (o, s)
        else:
            merged.append((o, s))
    return merged

def chains(pk, scmin=0.5, drift=8 * V):
    """pk[i] = candidate list for block i. dp[i][a] = weight of best chain
    ending at block i peak a. Chains extend only from block i-1."""
    n = len(pk)
    dp = [[s for o, s in p] for p in pk]
    fromp = [[None] * len(p) for p in pk]
    for i in range(1, n):
        for a, (o, s) in enumerate(pk[i]):
            best, arg = 0, None
            for b, (o2, s2) in enumerate(pk[i - 1]):
                if pk[i - 1] and abs((o - o2) - BLK) <= drift and s2 >= scmin:
                    if dp[i - 1][b] > best:
                        best, arg = dp[i - 1][b], b
            if arg is not None and s >= scmin:
                dp[i][a] += best
                fromp[i][a] = arg
    # collect maximal chains
    used = [set() for _ in range(n)]
    out = []
    ends = [(dp[i][a], i, a) for i in range(n) for a in range(len(pk[i])) if dp[i][a] > 0]
    for w, i, a in sorted(ends, reverse=True):
        seq, j = [], (i, a)
        while j is not None and j[1] not in used[j[0]]:
            used[j[0]].add(j[1])
            seq.append(j)
            j = (j[0] - 1, fromp[j[0]][j[1]]) if fromp[j[0]][j[1]] is not None else None
        if not seq:
            continue
        seq.reverse()
        scs = [pk[ii][aa][1] for ii, aa in seq]
        o0 = pk[seq[0][0]][seq[0][1]][0]
        o1 = pk[seq[-1][0]][seq[-1][1]][0] + BLK
        out.append([o0 / V, o1 / V, round(float(min(scs)), 2), len(seq),
                    seq[0][0] * BLK / V, seq[-1][0] * BLK / V + 40.0,
                    [round(pk[ii][aa][0] / V, 1) for ii, aa in seq]])
    nb = len(pk)
    keep = [c for c in out if c[3] >= 2 or (c[3] == 1 and c[2] >= 0.8 and nb <= 2)]
    return keep

def main(d, outj):
    e_old = envf(os.path.join(d, "old.raw"))
    nrmC = rollnorms(dec(e_old, DEC), BLK // DEC)
    nrmF = rollnorms(e_old, BLK)
    res = {}
    for p in sorted(glob.glob(os.path.join(d, "n_*.raw"))):
        if os.path.getsize(p) < 60000:
            continue
        name = os.path.basename(p)[:-4]
        e = envf(p)
        nb = len(e) // BLK
        pk = [peaks(e[i * BLK:(i + 1) * BLK], e_old, eC_cached, nrmC, nrmF)
              for i in range(nb)]
        res[name] = chains(pk)
        tot = sum(c[3] for c in res[name])
        print("%s blocks=%2d chains=%2d used=%2d" % (name, nb, len(res[name]), tot), flush=True)
    json.dump(res, open(outj, "w"))
    print("wrote", outj)

d = sys.argv[1]
eC_cached = None
def peaks_wrap(*a, **k): return peaks(*a, **k)
# load coarse env once for reuse inside peaks via closure hack
_orig_peaks = peaks
def _patch(d):
    global eC_cached
    eC_cached = dec(envf(os.path.join(d, "old.raw")), DEC)
_patch(d)
main(d, sys.argv[2])
