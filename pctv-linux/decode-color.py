#!/usr/bin/env python3
"""Colour decoder for PCTV 320cx analog captures.

Block header = BT.656 SAV  FF 00 00 XY  (XY = 1 F V H P3P2P1P0), payload
1440 bytes = one active line, 4:2:2  [Cb Y Cr Y] x 360.

F/V come straight from XY, so fields are found without guessing at blanking.

Usage: decode-color.py <capture.bin> <outdir> [tag]
  writes <tag>-field<n>.png (single field, bobbed to 576) in colour.
"""
import sys, os, zlib, struct
import numpy as np


def png_rgb(path, w, h, rgb):
    rgb = np.asarray(rgb).reshape(h, w, 3)
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgb[y].tobytes()
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    out += chunk(b"IEND", b"")
    open(path, "wb").write(out)


def png_gray(path, w, h, data):
    data = np.asarray(data).reshape(-1)
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += data[y * w:(y + 1) * w].tobytes()
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b""))


def yuv_to_rgb(y, cb, cr):
    """y: uint8 (16..235), cb/cr: uint8 (16..240).  Returns uint8 RGB."""
    Y = (y.astype(np.float32) - 16.0) * (255.0 / 219.0)
    Cb = (cb.astype(np.float32) - 128.0) * (255.0 / 224.0)
    Cr = (cr.astype(np.float32) - 128.0) * (255.0 / 224.0)
    r = Y + 1.402 * Cr
    g = Y - 0.344136 * Cb - 0.714136 * Cr
    b = Y + 1.772 * Cb
    return np.clip(np.stack([r, g, b], axis=-1), 0, 255).astype(np.uint8)


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
    return (a0 * (1 - f) + a1 * f).astype(a.dtype)


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    tag = sys.argv[3] if len(sys.argv) > 3 else "colour"
    os.makedirs(outdir, exist_ok=True)
    d = np.fromfile(src, dtype=np.uint8)
    n = d.size // 1444
    blk = d[:n * 1444].reshape(-1, 1444)
    xY = blk[:, 3].astype(int)
    F = (xY >> 6) & 1
    V = (xY >> 5) & 1
    pay = blk[:, 4:]
    Y = pay[:, 1::2]          # 720 luma samples
    Cb = pay[:, 0::4]         # 360 Cb
    Cr = pay[:, 2::4]         # 360 Cr
    print("%s: %d lines  F0 %d F1 %d  blanking %d  Cb std %.2f Cr std %.2f"
          % (src, n, int((F == 0).sum()), int((F == 1).sum()), int(V.sum()),
             Cb.std(), Cr.std()))

    # fields = maximal runs of V==0 (active) - each run is one field
    fields = []
    i = 0
    while i < n:
        if V[i] == 0:
            j = i
            while j < n and V[j] == 0:
                j += 1
            seg = slice(i, j)
            if j - i > 30:
                fields.append((F[i], seg))
            i = j
        else:
            i += 1
    print("fields: %d  heights %s" % (len(fields), [s.stop - s.start for _, s in fields[:8]]))

    nimg = 0
    for k, (fld, seg) in enumerate(fields[:6]):
        yy = Y[seg]
        cb = Cb[seg]
        cr = Cr[seg]
        # 4:2:2 -> 4:4:4 by duplicating chroma horizontally
        cb2 = np.repeat(cb, 2, axis=1)
        cr2 = np.repeat(cr, 2, axis=1)
        rgb = yuv_to_rgb(yy, cb2, cr2)
        rgb = resample_v(rgb, 576)
        png_rgb(os.path.join(outdir, "%s-field%d.png" % (tag, k)), 720, 576, rgb)
        png_gray(os.path.join(outdir, "%s-field%d-grey.png" % (tag, k)), 720, 576,
                 resample_v(yy, 576))
        nimg += 1
    print("wrote %d colour PNGs to %s" % (nimg, outdir))


main()
