#!/usr/bin/env python3
# Dell 12 merge planner. Builds an EDL in old-timeline order preferring the
# 2026 PCTV masters (better deinterlace) everywhere a DP chain covers cleanly;
# fills gaps and excised damage bands from the 2004 NVECapture files.
# Doctrine: excise sustained strict-blue bands (>=4 s of blue/s>=5 runs) with
# -0.9/+1.4 shoulders, merged within 1.5 s; short flashes stay.
import json, os
D = "/tmp/opencode/b12aud"
IDX = {}
for ln in open(os.path.join(D, "index.txt")):
    if "|" in ln:
        n, f = ln.strip().split("|", 1)
        IDX[n] = f
DMG = {}
for n in IDX:
    p = os.path.join(D, "d_%s.tsv" % n)
    if os.path.exists(p):
        m = {}
        for ln in open(p):
            s, t, b, h = map(int, ln.split())
            m[s] = (b, h)
        DMG[n] = m
OLD = []                                     # (cum0, cum1, path)
cum = 0.0
for ln in open(os.path.join(D, "oldmap.txt")):
    d, f = ln.split(maxsplit=1)
    OLD.append((cum, cum + float(d), f.strip())); cum += float(d)
TAPE = cum
chains = json.load(open("/tmp/opencode/b12dp.json"))

def oldsrc(s):
    for a, b, f in OLD:
        if a <= s < b:
            return f, s - a
    return None, 0

def dsec(n, s):                              # (blue,hi) at part-relative sec
    m = DMG.get(n, {})
    return m.get(int(s), (0, 0))

# ---- per chain: piecewise map + clean segments -----------------------------
cands = []                                    # dicts with old span + map fn parts
for n, chs in chains.items():
    if not chs:
        continue
    nn = n.split("_")[1]
    for c in chs:
        o0, o1, msc, nb, nw0, nw1, anch = c
        # piecewise map: old sec -> part sec (block k covers anchors[k]..+40)
        def mapp(s, anch=anch, nw0=nw0, o0=o0, o1=o1, npart=len(DMG.get(nn, {0: 0}))):
            for k in range(len(anch)):
                if anch[k] - 0.5 <= s < anch[k] + 40:
                    return nw0 + k * 40 + (s - anch[k])
            return min(max(nw0 + (s - o0), 0), max(npart - 1, 0))   # block-gap seconds: linear fallback
        covered = [(s, mapp(s)) for s in range(int(o0), int(o1))]
        # damage along old time
        bad = [s for s, ns in covered if ns is not None and dsec(nn, ns)[0] >= 3]
        runs, s = [], int(o0)
        badset = set(bad)
        cur = None
        for sec in range(int(o0), int(o1)):
            if sec in badset:
                if cur is None: cur = [sec, sec]
                else: cur[1] = sec
            else:
                if cur and sec - cur[1] > 2:
                    if cur[1] - cur[0] + 1 >= 4: runs.append(tuple(cur))
                    cur = None
        if cur and cur[1] - cur[0] + 1 >= 4: runs.append(tuple(cur))
        win = []
        for a, b in runs:
            w = [a - 0.9, b + 1.4]
            if win and w[0] - win[-1][1] <= 1.5: win[-1][1] = max(win[-1][1], w[1])
            else: win.append(w)
        # clean sub-segments
        segs, pos = [], float(o0)
        for w in win:
            if w[0] - pos >= 8: segs.append((pos, w[0]))
            pos = max(pos, w[1])
        if int(o1) - pos >= 8: segs.append((pos, float(o1)))
        for a, b in segs:
            bl = sum(dsec(nn, mapp(s))[0] for s in range(int(a), int(b)))
            cands.append(dict(part=nn, o0=a, o1=b, meanbl=bl / max(b - a, 1),
                              mapp=mapp))
cands.sort(key=lambda c: (c["o0"], -c["o1"]))

# ---- assemble ---------------------------------------------------------------
edl, t = [], 0.0
while t < TAPE - 1:
    nxt = [c for c in cands if c["o0"] <= t + 3 and c["o1"] >= t + 6]
    if nxt:
        c = min(nxt, key=lambda c: c["meanbl"])
        a = max(t, c["o0"]); b = c["o1"]
        edl.append(("NEW", c["part"], c["mapp"](a + 0.01), b - a, a, b, round(c["meanbl"], 2)))
        t = b
    else:
        nx = min((c["o0"] for c in cands if c["o0"] > t), default=TAPE)
        b = min(nx, t + 300)
        if nx - t < 0.75: b = nx
        f, loc = oldsrc(t)
        fend = [bb for a, bb, ff in OLD if ff == f][0]
        b = min(b, fend)
        edl.append(("OLD", os.path.basename(f), loc, b - t, t, b, 0))
        t = b
# merge adjacent same-source rows (old backfills, same part continuing)
edl2 = []
for r in edl:
    if edl2 and r[0] == edl2[-1][0] == "OLD" and r[1] == edl2[-1][1] and abs(r[2] - (edl2[-1][2] + edl2[-1][3])) < 0.2:
        e = list(edl2[-1]); e[3] += r[3]; e[5] = r[5]; edl2[-1] = tuple(e)
    elif edl2 and r[0] == edl2[-1][0] == "NEW" and r[1] == edl2[-1][1] and abs(r[2] - (edl2[-1][2] + edl2[-1][3])) < 0.2:
        e = list(edl2[-1]); e[3] += r[3]; e[5] = r[5]; edl2[-1] = tuple(e)
    else:
        edl2.append(r)
edl = edl2

# ---- report -----------------------------------------------------------------
newsec = sum(r[3] for r in edl if r[0] == "NEW")
print("segments=%d  new=%.0fs (%.0f%%)  old=%.0fs (%.0f%%)  out=%.1f min" %
      (len(edl), newsec, 100 * newsec / TAPE, TAPE - newsec, 100 * (TAPE - newsec) / TAPE, TAPE / 60))
byst = {}
for r in edl:
    k = r[0] if r[0] == "NEW" else r[1][-9:-4]
    byst[k] = byst.get(k, 0) + r[3]
print("by-source:", {k: round(v) for k, v in sorted(byst.items())})
with open("/tmp/opencode/b12edl.tsv", "w") as fo:
    for r in edl:
        print("%s\t%s\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f" % r, file=fo)
# coverage per old file
print("\nold-file  secs   new%%")
for a, b, f in OLD:
    ns = sum(min(b, r[5]) - max(a, r[4]) for r in edl if r[0] == "NEW" and r[5] > a and r[4] < b)
    print("%s %6.0f %5.1f" % (os.path.basename(f)[-9:-4], b - a, 100 * ns / (b - a)))
# 0007->0009 boundary check
x = [(r[0], r[1], round(r[4], 1), round(r[5], 1)) for r in edl if r[4] < 1975 and r[5] > 1955]
print("\naround old 1965 (0007/0009 boundary, the 0008 hole):", x)
