#!/usr/bin/env python3
"""Single-field decoder for PCTV 320cx analog captures, with optional
horizontal de-shear.

The block header is a BT.656 SAV (FF 00 00 XY); V (bit5) separates fields, so
active fields are maximal runs of V==0.  A single field already contains the
whole picture (the source is film/progressive), so the cleanest output is one
field bobbed to 576 lines.

The bridge delivers ~10k of the source's 15.6k lines/s at full width, and the
captured lines drift horizontally by a fraction of a pixel per line, so each
line is realigned before display.

Usage:
  decode-field.py <capture.bin> <outdir> [tag] [--index N] [--noshear]
                  [--height 576] [--grey]
"""
import sys, os, zlib, struct
import numpy as np


def png(path, w, h, arr):
    arr = np.asarray(arr)
    raw = bytearray()
    if arr.ndim == 2:
        for y in range(h):
            raw.append(0)
            raw += arr[y].reshape(-1).tobytes()
        ct = 0
    else:
        for y in range(h):
            raw.append(0)
            raw += np.ascontiguousarray(arr[y]).reshape(-1).tobytes()
        ct = 2
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


def resample_v(a, H):
    ys = np.linspace(0, a.shape[0] - 1, H)
    y0 = np.floor(ys).astype(int)
    y1 = np.minimum(y0 + 1, a.shape[0] - 1)
    f = (ys - y0)[:, None]
    a0 = a[y0].astype(np.float32)
    a1 = a[y1].astype(np.float32)
    if a.ndim == 3:
        f = f[:, :, None]
    return (a0 * (1 - f) + a1 * f).astype(a.dtype)


def best_shift(prev, cur, maxs=24):
    best = None
    for s in range(-maxs, maxs + 1):
        if s >= 0:
            a, b = prev[s:], cur[:len(cur) - s]
        else:
            a, b = prev[:len(prev) + s], cur[-s:]
        if a.size == 0:
            continue
        v = float(np.abs(a - b).mean())
        if best is None or v < best[0]:
            best = (v, s)
    return best[1] if best else 0


def deshear(lum):
    """Integer-align each row to the previous one; returns rolled rows and the
    cumulative shift trajectory."""
    h, w = lum.shape
    shifts = [0]
    for i in range(1, h):
        shifts.append(best_shift(lum[i - 1], lum[i]))
    cum = np.cumsum(shifts)
    out = np.empty_like(lum)
    for i in range(h):
        out[i] = np.roll(lum[i], -int(cum[i]))
    return out, cum


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    src, outdir = args[0], args[1]
    tag = args[2] if len(args) > 2 else "field"
    index = 0; H = 576; grey = False; shear = True
    for i, a in enumerate(sys.argv):
        if a == "--index":
            index = int(sys.argv[i + 1])
        elif a == "--height":
            H = int(sys.argv[i + 1])
        elif a == "--grey":
            grey = True
        elif a == "--noshear":
            shear = False
    os.makedirs(outdir, exist_ok=True)

    d = np.fromfile(src, dtype=np.uint8)
    n = d.size // 1444
    blk = d[:n * 1444].reshape(-1, 1444)
    xy = blk[:, 3].astype(int)
    F = (xy >> 6) & 1
    V = (xy >> 5) & 1
    pay = blk[:, 4:]
    Y = pay[:, 1::2]
    Cb = pay[:, 0::4]
    Cr = pay[:, 2::4]

    fields = []
    i = 0
    while i < n:
        if V[i] == 0:
            j = i
            while j < n and V[j] == 0:
                j += 1
            if j - i > 40:
                fields.append((i, j, int(F[i])))
            i = j
        else:
            i += 1
    print("%s: %d lines, %d fields, Cb std %.2f Cr std %.2f"
          % (src, n, len(fields), Cb.std(), Cr.std()))
    if not fields:
        print("no active fields"); return
    a, b, fld = fields[index % len(fields)]
    yy = Y[a:b]; cb = Cb[a:b]; cr = Cr[a:b]
    print("field %d: rows %d..%d (%d) F=%d" % (index, a, b, b - a, fld))
    if shear:
        yy, cum = deshear(yy)
        print("de-shear cumulative range %d..%d" % (cum.min(), cum.max()))
    if grey:
        png(os.path.join(outdir, "%s-%d.png" % (tag, index)), 720, H,
            resample_v(yy, H))
    else:
        cb2 = np.repeat(cb, 2, axis=1)
        cr2 = np.repeat(cr, 2, axis=1)
        rgb = yuv_to_rgb(yy, cb2, cr2)
        png(os.path.join(outdir, "%s-%d.png" % (tag, index)), 720, H,
            resample_v(rgb, H))
    print("wrote %s/%s-%d.png" % (outdir, tag, index))


main()
