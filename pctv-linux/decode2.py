#!/usr/bin/env python3
"""Decode a PCTV 320cx analog capture, correctly.

The analog stream (ENABLE_VIDEO = 0f 11 01 00, demod 1286 = 0x0000) is a
sequence of 1444-byte blocks:

    ff 00 00 ab | 1440 payload bytes = 720 BT.656-ish lines of [Cr Y Cb Y]

Currently the even byte (Cr/Cb) is pinned at 0x80 -> monochrome, but the
framing is:

    field = the lines between two vertical-blanking groups
    frame = two *interleaved* fields (PAL is 50 fields/s), NOT two stacked
            fields.

Usage:
  decode2.py <capture.bin> <outdir> [tag] [options]
    --mode all|interlace|field|continuous   (default all)
    --scale N        integer vertical upscale (nearest) for field/mode output
    --ascii          print an ASCII preview of the first field
"""
import sys, os, zlib, struct
import numpy as np


def png_gray(path, w, h, data):
    data = np.asarray(data).reshape(-1)
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += data[y * w:(y + 1) * w].tobytes()
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    out += chunk(b"IEND", b"")
    open(path, "wb").write(out)


def ascii_view(img, cols=100, rows=44):
    h, w = img.shape
    out = np.zeros((rows, cols), dtype=np.float32)
    for y in range(rows):
        for x in range(cols):
            out[y, x] = img[y * h // rows:(y + 1) * h // rows,
                           x * w // cols:(x + 1) * w // cols].mean()
    chars = " .:-=+*#%@"
    lo, hi = float(out.min()), float(out.max())
    rng = max(1.0, hi - lo)
    return "\n".join("".join(chars[min(9, int((out[y, x] - lo) * 9 / rng))]
                             for x in range(cols)) for y in range(rows))


def upscale_v(a, n):
    if n <= 1:
        return a
    return np.repeat(a, n, axis=0)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    src, outdir = args[0], args[1]
    tag = args[2] if len(args) > 2 else os.path.basename(src).split(".")[0]
    mode = "all"; scale = 1
    for i, a in enumerate(sys.argv):
        if a == "--mode":
            mode = sys.argv[i + 1]
        elif a == "--scale":
            scale = int(sys.argv[i + 1])
    os.makedirs(outdir, exist_ok=True)

    d = np.fromfile(src, dtype=np.uint8)
    nb = d.size // 1444
    if nb < 50:
        print("too small (%d blocks)" % nb); return
    blk = d[:nb * 1444].reshape(-1, 1444)
    pay = blk[:, 4:]
    even = pay[:, 0::2]
    lum = pay[:, 1::2].astype(np.uint8)          # (nb, 720)
    print("%s: %d blocks  header-ok %.3f  chroma-std %.2f (uniq %d)  luma %d..%d"
          % (src, nb, float((blk[:, 0] == 0xFF).mean()), even.std(),
             len(np.unique(even)), lum.min(), lum.max()))

    # vertical blanking = rows that are almost entirely idle 0x10
    frac_idle = (lum == 0x10).mean(axis=1)
    vbi = np.nonzero(frac_idle > 0.9)[0]
    groups = []
    if vbi.size:
        s = p = vbi[0]
        for r in vbi[1:]:
            if r - p > 3:
                groups.append((s, p)); s = r
            p = r
        groups.append((s, p))
    fields = []
    for i in range(len(groups) - 1):
        seg = lum[groups[i][1] + 1:groups[i + 1][0]]
        seg = seg[(seg == 0x10).mean(axis=1) < 0.9]
        if seg.shape[0] > 30:
            fields.append(seg)
    print("VBI groups %d -> %d fields, heights %s"
          % (len(groups), len(fields), [f.shape[0] for f in fields[:10]]))

    written = 0
    if mode in ("all", "field") and fields:
        for i, f in enumerate(fields[:6]):
            png_gray(os.path.join(outdir, "%s-field%d.png" % (tag, i)),
                     720, f.shape[0], upscale_v(f, scale))
            written += 1
    if mode in ("all", "interlace") and len(fields) >= 2:
        for i in range(0, min(len(fields) - 1, 12), 2):
            a, b = fields[i], fields[i + 1]
            n = min(a.shape[0], b.shape[0])
            inter = np.empty((2 * n, 720), dtype=np.uint8)
            inter[0::2] = a[:n]
            inter[1::2] = b[:n]
            if scale == 1:
                out = inter
            else:
                # gentle vertical stretch while interleaving
                out = upscale_v(inter, scale)
            png_gray(os.path.join(outdir, "%s-inter%02d.png" % (tag, i // 2)),
                     720, out.shape[0], out)
            written += 1
    if mode == "continuous":
        png_gray(os.path.join(outdir, "%s-continuous.png" % tag),
                 720, lum.shape[0], upscale_v(lum, scale))
        written += 1
    print("wrote %d PNGs to %s" % (written, outdir))

    if fields and "--ascii" in sys.argv:
        print("\nfield 0 (%dx%d):" % (720, fields[0].shape[0]))
        print(ascii_view(fields[0]))


main()
