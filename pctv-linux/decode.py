#!/usr/bin/env python3
"""Decode a PCTV 320cx analog-mode capture into PNG frames + an ASCII preview.

Analog arm (ENABLE_VIDEO = 0f 11 01 00) delivers 1444-byte blocks:
    ff 00 00 ab | 1440 payload bytes
With a live source the payload is BT.656-like: the even byte is 0x80 (neutral
chroma / idle phase) and the odd byte is the sample, so one block = one
720-sample luma line. The bridge frames ~10k blocks/s, i.e. it drops roughly a
third of the source's lines, so frames come out vertically decimated.

Usage: decode.py <capture.bin> <outdir> [tag] [--ascii]
"""
import sys, os, zlib, struct
import numpy as np


def png_gray(path, w, h, data):
    data = np.asarray(data).reshape(-1)  # accept 1-D or 2-D
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


def ascii_view(img, cols=72, rows=40):
    h, w = img.shape
    out = np.zeros((rows, cols), dtype=np.float32)
    for y in range(rows):
        for x in range(cols):
            out[y, x] = img[y * h // rows:(y + 1) * h // rows,
                           x * w // cols:(x + 1) * w // cols].mean()
    chars = " .:-=+*#%@"
    lo, hi = float(out.min()), float(out.max())
    return "\n".join("".join(chars[min(9, int((out[y, x] - lo) * 9 / max(1.0, hi - lo)))]
                         for x in range(cols)) for y in range(rows))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    src, outdir = args[0], args[1]
    tag = args[2] if len(args) > 2 else os.path.basename(src).split(".")[0]
    show = "--ascii" in sys.argv
    os.makedirs(outdir, exist_ok=True)

    d = np.fromfile(src, dtype=np.uint8)
    nb = d.size // 1444
    if nb < 200:
        print("too small (%d blocks)" % nb)
        return
    blk = d[:nb * 1444].reshape(-1, 1444)
    print("%s: %d bytes, %d blocks, header ok %.3f"
          % (src, d.size, nb, float((blk[:, 0] == 0xFF).mean())))
    pay = blk[:, 4:]
    print("even byte == 0x80 in %.4f of positions (luma-only bus)"
          % float((pay[:, 0::2] == 0x80).mean()))
    lum = pay[:, 1::2]
    print("luma min %d max %d mean %.1f  (BT.656 active range 0x10..0xEB)"
          % (lum.min(), lum.max(), lum.mean()))

    # line period: best row-to-row match
    flat = lum.reshape(-1)
    cand = []
    for W in range(660, 780):
        m = flat.size // W * W
        a = flat[:m].reshape(-1, W).astype(np.int16)
        cand.append((float(np.abs(a[1:] - a[:-1]).mean()), W))
    cand.sort()
    W = cand[0][1]
    a = flat[:flat.size // W * W].reshape(-1, W)
    print("line period %d samples (row diff %.2f; runners-up %s)"
          % (W, cand[0][0], [w for _, w in cand[1:4]]))

    # vertical blanking: rows that are almost entirely idle
    frac_idle = (a == 0x10).mean(axis=1)
    vbi = np.nonzero(frac_idle > 0.9)[0]
    groups = []
    if vbi.size:
        s = p = vbi[0]
        for r in vbi[1:]:
            if r - p > 3:
                groups.append((s, p)); s = r
            p = r
        groups.append((s, p))
    sp = [int(groups[i + 1][0] - groups[i][0]) for i in range(len(groups) - 1)]
    fp = int(np.median(sp)) if sp else 312
    print("VBI groups %d, field period median %d rows (samples %s)"
          % (len(groups), fp, sp[:8]))

    # fields: rows between consecutive VBI groups, idle rows dropped
    fields = []
    for i in range(len(groups) - 1):
        s = groups[i][1] + 1
        e = groups[i + 1][0]
        seg = a[s:e]
        seg = seg[(seg == 0x10).mean(axis=1) < 0.9]
        if seg.shape[0] > 50:
            fields.append(seg)
    print("fields: %d, heights %s" % (len(fields), [f.shape[0] for f in fields[:8]]))

    nimg = 0
    for i in range(0, len(fields) - 1, 2):
        for name, img in ((("field%d" % i), fields[i]),
                          (("frame%d" % (i // 2)), np.vstack([fields[i], fields[i + 1]]))):
            if nimg >= 24:
                break
            arr = np.clip(img, 0, 255).astype(np.uint8)
            png_gray(os.path.join(outdir, "%s-%s.png" % (tag, name)), W, arr.shape[0], arr)
            nimg += 1
        if nimg >= 24:
            break
    print("wrote %d PNGs to %s (%s-field*/frame*.png)" % (nimg, outdir, tag))

    if fields:
        print("\nASCII preview of field 0 (%dx%d):" % (W, fields[0].shape[0]))
        print(ascii_view(fields[0]))


main()
