#!/usr/bin/env python3
# Pin the 0008 hole: 1-s-window NCC of old tail-of-0007 and old head-of-0009
# against n_04 new 1230-1330. The gap between the two anchors = hole extents.
import numpy as np
SR, HOP = 2000.0, 100
def env16(x):
    n = len(x) // HOP
    e = np.abs(x[:n * HOP].astype(np.float32)).reshape(n, HOP).mean(axis=1)
    e = np.log1p(e); sd = e.std()
    if sd > 1e-6: e = np.clip((e - e.mean()) / sd, -4, 4)
    return (e - e.mean()).astype(np.float32)
def envf(p): return env16(np.fromfile(p, dtype=np.int16))
V = SR / HOP
e_old7 = envf("/tmp/opencode/b12aud/oldf_0007.raw")   # file-local seconds
e_old9 = envf("/tmp/opencode/b12aud/oldf_0009.raw")
x = np.fromfile("/tmp/opencode/b12aud/n_04.raw", dtype=np.int16)
for label, e_ref, w0, w1 in (("0007-tail", e_old7, len(e_old7) - 4 * V, len(e_old7)),
                             ("0009-head", e_old9, 0, 6 * V)):
    b = e_ref[int(w0):int(w1)]
    bb = b - b.mean(); nb = np.linalg.norm(bb)
    seg = x[int(1230 * SR):int(1330 * SR)]
    eb = env16(seg)
    c = np.correlate(eb, bb, "valid")
    w = len(bb)
    mu = np.convolve(eb, np.ones(w) / w, "valid")
    w2 = np.convolve(eb * eb, np.ones(w), "valid")
    sd = np.sqrt(np.maximum(w2 - w * mu * mu, 1e-9))
    sc = c / (sd * nb + 1e-9)
    order = np.argsort(sc)[::-1]
    seen, out = [], []
    for k in order:
        t = 1230 + k / V
        if all(abs(t - p) > 6 for p in seen):
            out.append((round(t, 1), round(float(sc[k]), 3))); seen.append(t)
        if len(out) >= 4: break
    print(label, "best n_04 positions (new sec, score):", out)
