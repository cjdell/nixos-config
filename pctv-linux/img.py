#!/usr/bin/env python3
"""Turn PCTV 320cx capture dumps into PNG frames so a human can verify them.

Usage: img.py <capture.bin> <outdir> [prefix]
Writes a set of candidate interpretations, each as one or more PNGs:
  raw-<W>       : bytes as-is, W pixels per row, 576 rows per frame
  ts-<W>        : 188-byte TS packets, 4-byte header stripped, W px rows
  blk-1440      : dib0700 analog-mode blocks (4-byte header + 1440 bytes)
  alt-<W>       : every other byte (kills the 80/10 clock alternation)
"""
import sys, os, zlib, struct
import numpy as np


def png_gray(path, w, h, data):
    """data: uint8 array of w*h (1-D or 2-D accepted)"""
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


def stats(a):
    return "n=%d mean=%.1f std=%.1f distinct=%d" % (
        len(a), a.mean(), a.std(), len(np.unique(a[:200000])))


def emit(outdir, prefix, tag, p, widths=(720, 858, 1440, 188)):
    for W in widths:
        H = 576 if p.size >= W * 576 else max(1, p.size // W)
        frames = min(3, p.size // (W * H))
        for f in range(frames):
            a = p[f * W * H:(f + 1) * W * H].astype(np.uint8)
            if a.size != W * H:
                continue
            path = os.path.join(outdir, "%s-%s-w%d-f%d.png" % (prefix, tag, W, f))
            png_gray(path, W, H, a)
            print("  %-46s %s" % (os.path.basename(path), stats(a)))


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    prefix = sys.argv[3] if len(sys.argv) > 3 else os.path.basename(src).split(".")[0]
    os.makedirs(outdir, exist_ok=True)
    d = np.fromfile(src, dtype=np.uint8)
    if d.size < 1000:
        print("%s: too small (%d bytes)" % (src, d.size))
        return
    print("%s: %d bytes, mean %.1f" % (src, d.size, d.mean()))

    emit(outdir, prefix, "raw", d)

    # TS framing?
    n188 = d.size // 188
    if n188 > 50:
        x = d[:n188 * 188].reshape(-1, 188)
        if float((x[:, 0] == 0x47).mean()) > 0.9:
            print("  TS framing detected (0x47 at every 188th byte)")
            emit(outdir, prefix, "ts", x[:, 4:].reshape(-1), widths=(720, 736, 858))

    # dib0700 analog-mode blocks: 4-byte header every 1444 bytes
    if d.size > 3000 and (d[0] == 0xFF or d[1444:1445].tobytes() == b"\xff"):
        blk = d[:(d.size // 1444) * 1444].reshape(-1, 1444)
        if float((blk[:, 0] == 0xFF).mean()) > 0.8:
            print("  analog block framing detected (1444-byte blocks)")
            emit(outdir, prefix, "blk", blk[:, 4:].reshape(-1), widths=(1440, 720, 360))

    # kill the 80/10 alternation
    emit(outdir, prefix, "alt", d[1::2], widths=(720, 360, 188))


main()
