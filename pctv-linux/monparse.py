#!/usr/bin/env python3
"""Parse the kernel usbmon binary API (/dev/usbmonN) into a readable trace.

struct mon_bin_hdr (drivers/usb/mon/mon_bin.c), 48 bytes on the wire:
  0x00 u64 id | 0x08 u8 type | 0x09 u8 xfer_type | 0x0a u8 epnum | 0x0b u8 devnum
  0x0c u16 busnum | 0x0e s8 flag_setup | 0x0f s8 flag_data
  0x10 s64 ts_sec | 0x18 s32 ts_usec | 0x1c s32 status
  0x20 u32 len_urb | 0x24 u32 len_cap | 0x28 u8 setup[8]
Data (len_cap bytes) follows the 48-byte header.
"""
import sys, struct

HDR = 48

def main(path, only_dev=None):
    d = open(path, 'rb').read()
    i = 0
    n = 0
    skipped = 0
    while i + HDR <= len(d):
        p = d[i:i+HDR]
        (ident, typ, xftype, epnum, devnum, busnum, fsetup, fdata,
         ts_sec, ts_usec, status, len_urb, len_cap) = struct.unpack_from(
            '<QBBBBHbbqiiII', p, 0)
        setup = p[40:48]
        data = b''
        if len_cap > 0 and len_cap < 8192:
            data = d[i+HDR:i+HDR+len_cap]
            i += HDR + len_cap
        else:
            i += HDR
        n += 1
        if only_dev and devnum != only_dev:
            skipped += 1
            continue
        t = chr(typ) if 32 <= typ < 127 else '?'
        line = "%14d.%06d  %s  dev=%-3d ep=%02x  xfer=%d  len_urb=%-6d cap=%-6d st=%d" % (
            ts_sec, ts_usec, t, devnum, epnum, xftype, len_urb, len_cap, status)
        if fsetup == 1 or (t == 'S' and setup != b'\0'*8):
            b8, breq, wvalue, windex, wlen = setup[0], setup[1], \
                setup[2] | setup[3] << 8, setup[4] | setup[5] << 8, setup[6] | setup[7] << 8
            line += "  setup %02x %02x %04x %04x %04x" % (b8, breq, wvalue, windex, wlen)
        if data:
            line += "\n            data: " + data[:128].hex()
            if len(data) > 128:
                line += " ...(%d)" % len(data)
        print(line)
    print("# %d events (%d filtered out), consumed %d of %d bytes"
          % (n, skipped, i, len(d)), file=sys.stderr)

if __name__ == '__main__':
    dev = int(sys.argv[2]) if len(sys.argv) > 2 else None
    main(sys.argv[1], dev)
