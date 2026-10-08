#!/usr/bin/env python3
"""BT.656 decoder for PCTV 320cx analog captures in video mode 2.

Why mode 2
----------
The dib0700 supports several analog output modes (`ENABLE_VIDEO` payload
byte 0x1X).  Mode 1 (0x11, what the vendor/driver uses) hands the bridge only
the *active* part of each BT.656 line (1444-byte blocks) and dribbles it out
at **15.3 MB/s** - less than the 27.0 MB/s a full PAL signal needs - so the
bridge silently drops 32% of lines.

Mode 2 (0x12) passes the *whole* BT.656 line (EAV + blanking + SAV + active =
1728 bytes) and reaches **25.6 MB/s**, i.e. ~95% of lines.  The remaining 5%
are still missing, but they are short, scattered gaps rather than a
mechanical 1-in-3.

Reconstruction
--------------
Both fields of a film frame carry the same picture, and the two fields lose
*different* lines, so the union of two consecutive fields recovers nearly all
288 lines.  `unify()` finds a monotonic alignment between the two fields'
rows (Needleman-Wunsch) and emits the union: rows seen in both come from A,
rows missing from A come from B.

Usage: decode-bt656.py <capture.bin> <outdir> [tag] [options]
  --index N          field to emit (default 0; -1 = most complete field)
  --align            unify the field with the next one to fill dropped lines
                     (default off: a straight rescale looks cleaner)
  --height N         output height (default 576)
  --gap N            alignment gap penalty (default 12)
  --chroma-median WxH
  --chroma-blur N
  --saturation F
  --grey
  --no-align         (default) rescale only, no gap filling
"""
import sys, os, zlib, struct
import numpy as np

LINE = 1728          # whole BT.656 line
ACTIVE = 1440        # active bytes after SAV
TARGET = 288         # active lines in a PAL field
GAP = 12             # DP gap penalty (mean-abs cost between rows is ~5-40)


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


def box_filter(a, r):
    c = np.cumsum(np.pad(a, ((0, 0), (r + 1, r)), mode="edge"), axis=1)
    h = (c[:, 2 * r + 1:] - c[:, :-2 * r - 1]) / (2 * r + 1)
    c = np.cumsum(np.pad(h, ((r + 1, r), (0, 0)), mode="edge"), axis=0)
    return (c[2 * r + 1:] - c[:-2 * r - 1]) / (2 * r + 1)


def median_filter(a, k=(3, 3)):
    from numpy.lib.stride_tricks import sliding_window_view
    ph = (k[0] // 2, k[1] // 2)
    w = sliding_window_view(np.pad(a, ((ph[0], ph[0]), (ph[1], ph[1])),
                                  mode="edge"), k)
    return np.median(w, axis=(-1, -2))


def resample_v(a, H):
    ys = np.linspace(0, a.shape[0] - 1, H)
    y0 = np.floor(ys).astype(int)
    y1 = np.minimum(y0 + 1, a.shape[0] - 1)
    f = (ys - y0)[:, None]
    a0 = a[y0].astype(np.float32); a1 = a[y1].astype(np.float32)
    if a.ndim == 3:
        f = f[:, :, None]
    return (a0 * (1 - f) + a1 * f).astype(a.dtype)


def parse(d):
    """Split the stream into BT.656 lines.  Returns (Y, Cb, Cr, F, V)."""
    sync = np.nonzero((d[:-4] == 0xFF) & (d[1:-3] == 0x00) & (d[2:-2] == 0x00))[0]
    xy = d[sync + 3].astype(int)
    sav = sync[(xy & 0x10) == 0]                 # SAV has H=0
    sxy = xy[(xy & 0x10) == 0]
    good = sav + 4 + ACTIVE <= d.size
    sav, sxy = sav[good], sxy[good]
    idx = sav[:, None] + 4 + np.arange(ACTIVE)[None, :]
    pay = d[idx]
    Y = pay[:, 1::2].astype(np.float32)
    Cb = pay[:, 0::4].astype(np.float32)
    Cr = pay[:, 2::4].astype(np.float32)
    return Y, Cb, Cr, (sxy >> 6) & 1, (sxy >> 5) & 1


def field_runs(V, min_len=30):
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


def unify(rows, oth, feat=None, gap=GAP):
    """Monotonic alignment of two row sequences; return the union index map.

    Both are subsequences of the same field (each with its own dropped lines),
    so the union should restore the full ~288 rows.  Returns a list of
    (kind, i, j) with kind 'a' (rows[i]), 'b' (oths[j]) or 'ab' (both)."""
    n, m = rows.shape[0], oth.shape[0]
    A = feat(rows) if feat else rows
    B = feat(oth) if feat else oth
    C = np.empty((n, m), dtype=np.float32)
    for i in range(n):
        C[i] = np.abs(A[i][None, :] - B).mean(axis=1)
    D = np.full((n + 1, m + 1), np.inf, dtype=np.float32)
    T = np.zeros((n + 1, m + 1), dtype=np.uint8)
    D[0, 0] = 0
    for i in range(1, n + 1):
        D[i, 0] = gap * i; T[i, 0] = 1
    for j in range(1, m + 1):
        D[0, j] = gap * j; T[0, j] = 2
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d0 = D[i - 1, j - 1] + C[i - 1, j - 1]
            d1 = D[i - 1, j] + gap
            d2 = D[i, j - 1] + gap
            if d0 <= d1 and d0 <= d2:
                D[i, j] = d0; T[i, j] = 0
            elif d1 <= d2:
                D[i, j] = d1; T[i, j] = 1
            else:
                D[i, j] = d2; T[i, j] = 2
    out = []; i, j = n, m
    while i > 0 or j > 0:
        t = T[i, j]
        if t == 0:
            out.append(("ab", i - 1, j - 1)); i -= 1; j -= 1
        elif t == 1:
            out.append(("a", i - 1, None)); i -= 1
        else:
            out.append(("b", None, j - 1)); j -= 1
    out.reverse()
    return out


def build(pairs, mapping):
    """Materialise the unified row sequence for each (rows, oth) pair."""
    outs = [[] for _ in pairs]
    for kind, i, j in mapping:
        for o, (rows, oth) in zip(outs, pairs):
            o.append(rows[i] if kind != "b" else oth[j])
    return [np.vstack(o) for o in outs]


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    src, outdir = args[0], args[1]
    tag = args[2] if len(args) > 2 else "bt656"
    index, H, blur, sat, grey, align = 0, 576, 0, 1.0, False, False
    median = (0, 0)
    gap = GAP
    for i, x in enumerate(sys.argv):
        if x == "--index": index = int(sys.argv[i + 1])
        elif x == "--height": H = int(sys.argv[i + 1])
        elif x == "--gap": gap = int(sys.argv[i + 1])
        elif x == "--chroma-blur": blur = int(sys.argv[i + 1])
        elif x == "--saturation": sat = float(sys.argv[i + 1])
        elif x == "--chroma-median":
            wh = sys.argv[i + 1].split("x")
            median = (int(wh[0]), int(wh[1]) if len(wh) > 1 else int(wh[0]))
        elif x == "--align": align = True
        elif x == "--no-align": align = False
        elif x == "--grey": grey = True
    os.makedirs(outdir, exist_ok=True)

    d = np.fromfile(src, dtype=np.uint8)
    Y, Cb, Cr, F, V = parse(d)
    runs = field_runs(V)
    print("%s: %d lines, %d lines/s, %d fields  Cb std %.2f Cr std %.2f"
          % (src, Y.shape[0], Y.shape[0], len(runs), Cb.std(), Cr.std()))
    print("  field heights %s" % [b - a for a, b in runs[:12]])
    if not runs:
        print("no fields"); return

    k = index % max(1, len(runs))
    if index < 0:
        # pick the most complete field: a full 288-line field is ideal (290
        # means spurious boundary rows, less than 288 means dropped lines).
        # Ignore mis-detected merged runs (>TARGET+6).
        cand = [i for i in range(len(runs) - 1)
                if runs[i][1] - runs[i][0] <= TARGET + 6]
        k = min(cand, key=lambda i: (runs[i][1] - runs[i][0] != TARGET,
                                     abs(runs[i][1] - runs[i][0] - TARGET))) \
            if cand else 0
        print("  --best: chose field %d (%d rows)" % (k, runs[k][1] - runs[k][0]))
    a, b = runs[k]
    rows, cb, cr = Y[a:b], Cb[a:b], Cr[a:b]
    print("  field %d: %d active rows (ideal %d)" % (k, rows.shape[0], TARGET))
    if align and k + 1 < len(runs) and rows.shape[0] < TARGET - 2:
        a2, b2 = runs[k + 1]
        oth, ocb, ocr = Y[a2:b2], Cb[a2:b2], Cr[a2:b2]
        # rows are ~1 KB each; downsample columns for the alignment cost
        feat = lambda x: x[:, ::16]
        mp = unify(rows, oth, feat, gap)
        before = rows.shape[0]
        rows, cb, cr = build([(rows, oth), (cb, ocb), (cr, ocr)], mp)
        added = sum(1 for kk, _, _ in mp if kk == "b")
        print("  unified with field %d (gap %d): %d + %d recovered -> %d rows"
              % (k + 1, gap, before, added, rows.shape[0]))
    if align and rows.shape[0] != TARGET:
        print("  normalising %d -> %d rows" % (rows.shape[0], TARGET))
        rows = resample_v(rows, TARGET)
        cb = resample_v(cb, TARGET)
        cr = resample_v(cr, TARGET)
    else:
        # No gap filling.  Mode 2 loses only ~3%% of lines (scattered singles),
        # so a straight rescale of whatever arrived is clean - the tiny
        # vertical stretch is invisible, and nothing is invented.
        print("  rescaling %d rows straight to %d (no gap filling)"
              % (rows.shape[0], H))
    if median != (0, 0):
        cb, cr = median_filter(cb, median), median_filter(cr, median)
    if blur > 0:
        cb, cr = box_filter(cb, blur), box_filter(cr, blur)
    if sat != 1.0:
        cb, cr = 128.0 + (cb - 128.0) * sat, 128.0 + (cr - 128.0) * sat
    if grey:
        png(os.path.join(outdir, "%s-%d.png" % (tag, index)), 720, H,
            resample_v(rows, H).astype(np.uint8))
    else:
        rgb = yuv_to_rgb(rows, np.repeat(cb, 2, axis=1), np.repeat(cr, 2, axis=1))
        png(os.path.join(outdir, "%s-%d.png" % (tag, index)), 720, H,
            resample_v(rgb, H))
    print("  wrote %s/%s-%d.png" % (outdir, tag, index))


main()
