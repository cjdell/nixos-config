#!/usr/bin/env python3
# 5-s NCC path through the 0008-hole crossing: n_04 new 1080-1440 vs old 1880-2120.
import numpy as np, os, json
SR, HOP = 2000.0, 100
def env16(x):
    n = len(x) // HOP
    e = np.abs(x[:n * HOP].astype(np.float32)).reshape(n, HOP).mean(axis=1)
    e = np.log1p(e); sd = e.std()
    if sd > 1e-6: e = np.clip((e - e.mean()) / sd, -4, 4)
    return (e - e.mean()).astype(np.float32)
def envf(p): return env16(np.fromfile(p, dtype=np.int16))

d = "/tmp/opencode/b12aud"
e_old = envf(d + "/old.raw")
x = np.fromfile(d + "/n_04.raw", dtype=np.int16)
V = SR / HOP                       # vectors per second
lo0, hi0 = int(1880 * V), int(2120 * V)
for t0 in np.arange(1080, 1440, 5):
    b = env16(x[int(t0 * SR):int((t0 + 5) * SR)])
    bb = b - b.mean(); nb = np.linalg.norm(bb)
    w = int(5 * V)
    seg = e_old[lo0:hi0 + w]
    c = np.correlate(seg, bb, "valid")
    mu = (seg[:len(c)].reshape(-1, w).mean(axis=1) if False else
          np.convolve(e_old[lo0:hi0 + w], np.ones(w) / w, "valid")[:len(c)])
    w2 = np.convolve(e_old[lo0:hi0 + w] ** 2, np.ones(w), "valid")[:len(c)]
    sd = np.sqrt(np.maximum(w2 - w * mu * mu, 1e-9))
    sc = c / (sd * nb + 1e-9)
    k = int(np.argmax(sc))
    print("new %6.1f -> old %6.1f  sc=%+.3f" % (t0, lo0 / V + k / V, sc[k]), flush=True)
