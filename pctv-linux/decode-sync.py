#!/usr/bin/env python3
"""Sync-locked decode of a PCTV 320cx analog-mode capture.

The dib0700 frames 1444-byte blocks on its own clock, so the block boundary
drifts through the source's lines: fixed-width framing shears the picture
(~1 px per line, which is the 45-degree skew). Fix: find the source's own line
syncs in the stream, cut each line at its sync, and resample to a fixed width.

Stream layout (analog arm ENABLE_VIDEO = 0f 11 01 00):
    1444-byte block = ff 00 00 ab | 1440 payload bytes
    payload even byte = 0x80 always, odd byte = BT.656 luma sample

Usage: decode-sync.py <capture.bin> <outdir> [tag] [--ascii]
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


def ascii_view(img, cols=74, rows=36):
    h, w = img.shape
    o = np.zeros((rows, cols), np.float32)
    for y in range(rows):
        for x in range(cols):
            o[y, x] = img[y * h // rows:(y + 1) * h // rows,
                         x * w // cols:(x + 1) * w // cols].mean()
    ch = " .:-=+*#%@"
    lo, hi = float(o.min()), float(o.max())
    return "\n".join("".join(ch[min(9, int((o[y, x] - lo) * 9 / max(1.0, hi - lo)))]
                         for x in range(cols)) for y in range(rows))


def resample(seg, out_len):
    """linear interpolation of a 1-D segment to out_len samples"""
    n = len(seg)
    if n < 8:
        return np.full(out_len, 0x10, dtype=np.float32)
    x = np.linspace(0, n - 1, out_len)
    i0 = np.floor(x).astype(np.int64)
    i1 = np.minimum(i0 + 1, n - 1)
    f = x - i0
    return (1 - f) * seg[i0] + f * seg[i1]


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
    pay = d[:nb * 1444].reshape(-1, 1444)[:, 4:]
    lum = pay[:, 1::2].reshape(-1).astype(np.float32)
    print("%s: %d blocks, %d luma samples, even byte 0x80 in %.4f"
          % (src, nb, lum.size, float((pay[:, 0::2] == 0x80).mean())))

    # ---- line syncs: end of an idle (0x10) run, i.e. idle -> active edge ----
    idle = lum <= 0x11
    # require a run of >= 6 idle samples before the edge
    cs = np.concatenate(([0.0], np.cumsum(idle)))
    edge = np.nonzero((~idle[1:]) & idle[:-1])[0] + 1
    edge = edge[(cs[edge] - cs[np.maximum(edge - 6, 0)]) >= 6]
    print("idle->active edges: %d" % edge.size)

    # accept edges that continue the line sequence
    syncs = [edge[0]]
    for e in edge[1:]:
        gap = e - syncs[-1]
        if 640 <= gap <= 800:
            syncs.append(e)
        elif 1280 <= gap <= 1600:          # a line whose sync was missed
            syncs.append(e - 720)
            syncs.append(e)
        elif gap > 1600:                  # lost lock (VBI / dropout): resync
            syncs.append(e)
    syncs = np.array(syncs)
    gaps = np.diff(syncs)
    print("syncs: %d, spacing median %d mean %.2f std %.2f"
          % (syncs.size, int(np.median(gaps)), gaps.mean(), gaps.std()))

    # ---- cut each line at its sync and resample to a fixed width ----
    W = 720
    lines = np.stack([resample(lum[s:e], W) for s, e in zip(syncs[:-1], syncs[1:])])
    lines = np.clip(lines, 0, 255)
    print("lines: %d x %d" % lines.shape)

    # ---- vertical blanking: lines that are mostly idle ----
    frac_idle = (lines <= 0x11).mean(axis=1)
    vbi = frac_idle > 0.75
    # group into fields
    fields, cur = [], []
    run = 0
    for i in range(len(lines)):
        if vbi[i]:
            run += 1
            if cur and run >= 3:
                fields.append(np.vstack(cur)); cur = []; run = 0
        else:
            cur.append(lines[i]); run = 0
    if cur:
        fields.append(np.vstack(cur))
    heights = [f.shape[0] for f in fields]
    print("fields: %d, heights %s" % (len(fields), heights[:10]))

    nimg = 0
    for i in range(len(fields)):
        if nimg >= 12:
            break
        arr = fields[i].astype(np.uint8)
        png_gray(os.path.join(outdir, "%s-field%d.png" % (tag, i)), W, arr.shape[0], arr)
        nimg += 1
        if i + 1 < len(fields):
            both = np.vstack([fields[i], fields[i + 1]])
            png_gray(os.path.join(outdir, "%s-frame%d.png" % (tag, i // 2)),
                     W, both.shape[0], both.astype(np.uint8))
            nimg += 1
    print("wrote %d PNGs to %s" % (nimg, outdir))

    if fields:
        print("\nsync-locked field 0 (%dx%d):" % (W, fields[0].shape[0]))
        print(ascii_view(fields[0]))


main()
