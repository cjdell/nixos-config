#!/usr/bin/env python3
"""Clean decoder for PCTV 320cx analog captures.

Stream format
-------------
Each 1444-byte block is  FF 00 00 XY  + 1440 bytes of one BT.656 line.
XY = 1 F V H P3..P0 :  F = field, V = vertical blanking.
Payload = 4:2:2  [Cb Y Cr Y] x 360  ->  720 luma, 360 Cb, 360 Cr.

What has to be undone
---------------------
**The bridge drops lines.**  It moves ~15 MB/s; at full 720-px the source
needs ~22.5 MB/s.  The gap *positions* are regular - 32 captured lines, then
a chunk is lost - but the chunk size varies (15-20 lines), so the repair is
per field: each field's deficit (target - captured) is spread over its own
gaps.

Interpolating those gaps smears ~30% of the picture.  Because consecutive
fields carry the same picture (film source), the missing rows of one field
are usually *real* rows in its neighbour, so two fields are merged
(`--merge`, the default) and only the residue is interpolated.

Chroma is gated by the CX25843 colour killer (reg 0x401 bit 6); the vendor
init leaves it on, which pins Cb/Cr to 0x80 and gives a grey picture.

Usage: decode-clean.py <capture.bin> <outdir> [tag] [options]
  --gap N      gap period in captured lines (default 32, 0 = no repair)
  --target N   active lines per field to restore to (default 290)
  --phase N    absolute captured index of the first gap (default: detect)
  --index N    which field to emit (default 0)
  --merge      merge field N with N+1 to recover dropped rows (default on)
  --no-merge   disable merging (interpolate only)
  --align-bands  horizontally roll merge bands (off by default - it shifts
                 the black bars; see merge() docstring)
  --height N   output height (default 576)
  --chroma-blur N  box-filter radius to denoise chroma (0 = off)
  --chroma-median WxH  median filter chroma (kills cross-colour speckle)
  --saturation F   software chroma gain (default 1.0; 1.3 = +30%)
  --grey       luma only
"""
import sys, os, zlib, struct
import numpy as np


def png(path, w, h, arr):
    arr = np.asarray(arr)
    raw = bytearray()
    ct = 0 if arr.ndim == 2 else 2
    for y in range(h):
        raw.append(0)
        raw += np.ascontiguousarray(arr[y]).reshape(-1).tobytes()
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ct, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b""))


def yuv_to_rgb(y, cb, cr):
    Y = (y.astype(np.float32) - 16.0) * (255.0 / 219.0)
    Cb = (cb.astype(np.float32) - 128.0) * (255.0 / 224.0)
    Cr = (cr.astype(np.float32) - 128.0) * (255.0 / 224.0)
    r = Y + 1.402 * Cr
    g = Y - 0.344136 * Cb - 0.714136 * Cr
    b = Y + 1.772 * Cb
    return np.clip(np.stack([r, g, b], -1), 0, 255).astype(np.uint8)


def median_filter(a, k=(3, 3)):
    from numpy.lib.stride_tricks import sliding_window_view
    ph = (k[0] // 2, k[1] // 2)
    w = sliding_window_view(np.pad(a, ((ph[0], ph[0]), (ph[1], ph[1])),
                                  mode="edge"), k)
    return np.median(w, axis=(-1, -2))


def box_filter(a, r):
    c = np.cumsum(np.pad(a, ((0, 0), (r + 1, r)), mode="edge"), axis=1)
    h = (c[:, 2 * r + 1:] - c[:, :-2 * r - 1]) / (2 * r + 1)
    c = np.cumsum(np.pad(h, ((r + 1, r), (0, 0)), mode="edge"), axis=0)
    return (c[2 * r + 1:] - c[:-2 * r - 1]) / (2 * r + 1)


def resample_v(a, H):
    ys = np.linspace(0, a.shape[0] - 1, H)
    y0 = np.floor(ys).astype(int)
    y1 = np.minimum(y0 + 1, a.shape[0] - 1)
    f = (ys - y0)[:, None]
    a0 = a[y0].astype(np.float32); a1 = a[y1].astype(np.float32)
    if a.ndim == 3:
        f = f[:, :, None]
    return (a0 * (1 - f) + a1 * f).astype(a.dtype)


def detect_phase(Y, V, gap):
    act = np.nonzero(V == 0)[0]
    if act.size < 200:
        return 0
    seg = Y[act[0]:act[-1] + 1].astype(np.float32)
    D = np.abs(np.diff(seg, axis=0)).mean(axis=1)
    thr = np.median(D) * 2.5 + 0.5
    p = np.nonzero(D > thr)[0]
    if p.size == 0:
        return 0
    vals, counts = np.unique((p + act[0]) % gap, return_counts=True)
    return int(vals[np.argmax(counts)])


def field_runs(V, min_len=40):
    runs = []; i = 0
    while i < len(V):
        if V[i] == 0:
            j = i
            while j < len(V) and V[j] == 0:
                j += 1
            if j - i > min_len:
                runs.append((i, j))
            i = j
        else:
            i += 1
    return runs


def repair_field(Y, Cb, Cr, a, b, phase, gap, target):
    """Return rows + a mask (1 = real captured line, 0 = interpolated)."""
    L = b - a
    need = target - L
    gaps = [g for g in range(a, b - 1) if (g % gap) == phase]
    if need <= 0 or not gaps:
        return (Y[a:b], Cb[a:b], Cr[a:b],
                np.ones(L, dtype=np.uint8), [])
    base, extra = divmod(need, len(gaps))
    ys = [Y[a]]; cbs = [Cb[a]]; crs = [Cr[a]]
    ms = [np.ones(1, dtype=np.uint8)]
    added = []
    for cur in range(a, b - 1):
        if (cur % gap) == phase:
            n = base + (1 if len(added) < extra else 0)
            added.append(n)
            if n > 0:
                t = np.linspace(0, 1, n + 2)[1:-1][:, None]
                ys.append(Y[cur] * (1 - t) + Y[cur + 1] * t)
                cbs.append(Cb[cur] * (1 - t) + Cb[cur + 1] * t)
                crs.append(Cr[cur] * (1 - t) + Cr[cur + 1] * t)
                ms.append(np.zeros(n, dtype=np.uint8))
        ys.append(Y[cur + 1]); cbs.append(Cb[cur + 1]); crs.append(Cr[cur + 1])
        ms.append(np.ones(1, dtype=np.uint8))
    return np.vstack(ys), np.vstack(cbs), np.vstack(crs), np.concatenate(ms), added


def best_vshift(A, mA, B, mB, maxs=10):
    """Vertical shift s so that B[i+s] best matches A[i] over rows real in both."""
    L = A.shape[0]
    best = (-2.0, 0)
    for s in range(-maxs, maxs + 1):
        i = np.arange(L)
        j = i + s
        ok = (j >= 0) & (j < L)
        jc = np.clip(j, 0, L - 1)
        m = ok & (mA > 0) & (mB[jc] > 0)
        if m.sum() < 80:
            continue
        a = A[m].astype(np.float32).ravel()
        b = B[jc][m].astype(np.float32).ravel()
        if a.std() < 1e-3 or b.std() < 1e-3:
            continue
        c = float(np.corrcoef(a, b)[0, 1])
        if c > best[0]:
            best = (c, s)
    return best


def best_roll(p, q, maxr=8):
    """Horizontal roll of q that best matches p."""
    best = None
    for r in range(-maxr, maxr + 1):
        v = float(np.abs(p - np.roll(q, r)).mean())
        if best is None or v < best[0]:
            best = (v, r)
    return best[1]


def merge(A, mA, B, mB, s, planes=(), align=False):
    """Prefer A's real rows, fill A's holes from B (shifted by s).

    NOTE: `align=True` (horizontal band alignment) is off by default.  It was
    added to chase a suspected phase difference between the two fields, but
    the fields' black bars line up exactly (both at x=87) - the correlation
    that suggested otherwise was tracking dark, low-contrast content.  The
    roll it applied shifted the black bars sideways in bands, which is far
    more visible than the artifact it was meant to fix.  Kept for reference.
    """
    L = A.shape[0]
    i = np.arange(L)
    j = np.clip(i + s, 0, L - 1)
    take = (mA == 0) & (mB[j] > 0)
    outA = A.copy()
    outs = [p.copy() for p in planes]
    idx = np.nonzero(take)[0]
    if idx.size:
        splits = np.nonzero(np.diff(idx) > 1)[0] + 1
        for band in np.split(idx, splits):
            i0, i1 = band[0], band[-1]
            r = 0
            if align:
                refs = []
                if i0 - 1 >= 0 and mA[i0 - 1] > 0:
                    refs.append(best_roll(A[i0 - 1], B[j[i0]]))
                if i1 + 1 < L and mA[i1 + 1] > 0:
                    refs.append(best_roll(A[i1 + 1], B[j[i1]]))
                if refs:
                    r = int(round(float(np.mean(refs))))
            outA[band] = np.roll(B[j[band]], r, axis=1) if r else B[j[band]]
            for o, p in zip(outs, planes):
                o[band] = np.roll(p[j[band]], r, axis=1) if r else p[j[band]]
    m = mA.copy()
    m[take] = 1
    return outA, m, outs, int(take.sum())


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    src, outdir = args[0], args[1]
    tag = args[2] if len(args) > 2 else "clean"
    gap, target, index, H, grey, blur = 32, 290, 0, 576, False, 0
    do_merge = True
    align = False
    median = (0, 0)
    sat = 1.0
    phase = -1
    for i, x in enumerate(sys.argv):
        if x == "--gap": gap = int(sys.argv[i + 1])
        elif x == "--target": target = int(sys.argv[i + 1])
        elif x == "--phase": phase = int(sys.argv[i + 1])
        elif x == "--index": index = int(sys.argv[i + 1])
        elif x == "--height": H = int(sys.argv[i + 1])
        elif x == "--chroma-blur": blur = int(sys.argv[i + 1])
        elif x == "--saturation": sat = float(sys.argv[i + 1])
        elif x == "--chroma-median":
            wh = sys.argv[i + 1].split("x")
            median = (int(wh[0]), int(wh[1]) if len(wh) > 1 else int(wh[0]))
        elif x == "--merge": do_merge = True
        elif x == "--no-merge": do_merge = False
        elif x == "--align-bands": align = True
        elif x == "--grey": grey = True
    os.makedirs(outdir, exist_ok=True)

    d = np.fromfile(src, dtype=np.uint8)
    n = d.size // 1444
    blk = d[:n * 1444].reshape(-1, 1444)
    xy = blk[:, 3].astype(int)
    V = (xy >> 5) & 1
    pay = blk[:, 4:]
    Y = pay[:, 1::2].astype(np.float32)
    Cb = pay[:, 0::4].astype(np.float32)
    Cr = pay[:, 2::4].astype(np.float32)

    if phase < 0 and gap:
        phase = detect_phase(pay[:, 1::2].astype(np.int16), V, gap)
    runs = field_runs(V)
    print("%s: %d lines, %d fields  Cb std %.2f Cr std %.2f  gap phase %d/%d"
          % (src, n, len(runs), Cb.std(), Cr.std(), phase, gap))
    if not runs:
        print("no active fields"); return

    idx = index % len(runs)
    a, b = runs[idx]
    A, ACb, ACr, mA, addA = repair_field(Y, Cb, Cr, a, b, phase, gap, target)
    print("  field %d: %d captured -> %d (%d gaps, %d interpolated)"
          % (idx, b - a, A.shape[0], len(addA), int((mA == 0).sum())))
    if do_merge and idx + 1 < len(runs):
        a2, b2 = runs[idx + 1]
        B, BCb, BCr, mB, _ = repair_field(Y, Cb, Cr, a2, b2, phase, gap, target)
        c, s = best_vshift(A, mA, B, mB)
        A, mA, (ACb, ACr), got = merge(A, mA, B, mB, s, (ACb, ACr), align)
        print("  merged with field %d (shift %+d, corr %.3f): recovered %d rows, "
              "%d still interpolated" % (idx + 1, s, c, got, int((mA == 0).sum())))
    yy, cb, cr = A, ACb, ACr
    if median != (0, 0):
        cb = median_filter(cb, median)
        cr = median_filter(cr, median)
    if blur > 0:
        cb = box_filter(cb, blur)
        cr = box_filter(cr, blur)
    if sat != 1.0:
        cb = 128.0 + (cb - 128.0) * sat
        cr = 128.0 + (cr - 128.0) * sat
    if grey:
        png(os.path.join(outdir, "%s-%d.png" % (tag, idx)), 720, H,
            resample_v(yy, H).astype(np.uint8))
    else:
        rgb = yuv_to_rgb(yy, np.repeat(cb, 2, axis=1), np.repeat(cr, 2, axis=1))
        png(os.path.join(outdir, "%s-%d.png" % (tag, idx)), 720, H,
            resample_v(rgb, H))
    print("  wrote %s/%s-%d.png" % (outdir, tag, idx))


main()
