#!/usr/bin/env python3
"""Proper usbmon decoder for the DiB0700 vendor protocol.

Handles legacy (0x02/0x03) and new (0x12/0x13) i2c APIs, decodes the i2c
payload for both the DiB7000P (1-byte reg + 16-bit val) and the CX2584x
(2-byte reg + 8/32-bit val), and prints every other vendor request raw.

usage: dec.py <file.parsed> [ts_lo ts_hi]
"""
import sys, re

RQ = {
    '02': 'I2C_READ(legacy)', '03': 'I2C_WRITE(legacy)', '04': 'MPEG_MODE',
    '05': 'I2C_BULK', '06': 'RQ_06', '07': 'GET_VERSION', '08': 'RQ_08',
    '09': 'RQ_09', '0a': 'RQ_0A', '0b': 'SET_CLOCK', '0c': 'SET_GPIO',
    '0d': 'RQ_0D', '0e': 'RQ_0E', '0f': 'ENABLE_VIDEO',
    '10': 'XFER_LEN', '11': 'SETUP_DEMOD', '12': 'NEW_I2C_READ',
    '13': 'NEW_I2C_WRITE', '14': 'RQ_14', '15': 'RQ_15', '16': 'RQ_16',
    '17': 'RQ_17', '18': 'RQ_18', '19': 'RQ_19', '1a': 'RQ_1A', '1b': 'RQ_1B',
    '1c': 'RQ_1C', '1d': 'RQ_1D', '1e': 'RQ_1E', '1f': 'RQ_1F',
}

def hx(b): return ' '.join('%02x' % c for c in b)

def classify_i2c(addr8, payload):
    """Return best-guess decodings of an i2c write payload."""
    out = []
    p = payload
    if len(p) == 4:
        # DiB7000P style: reg = [0]&7<<8 | [1], value = [2]<<8|[3]
        reg = ((p[0] & 0x0f) << 8) | p[1]
        out.append("dib? reg=%d val=0x%04x" % (reg, (p[2] << 8) | p[3]))
    if len(p) in (3, 4, 5, 6):
        reg = (p[0] << 8) | p[1]
        if reg <= 0xfff:
            out.append("cx?  reg=0x%03x val=[%s]" % (reg, hx(p[2:])))
    if len(p) == 2:
        out.append("byte? reg=0x%02x val=0x%02x" % (p[0], p[1]))
    return ' | '.join(out) if out else ''

def main():
    fn = sys.argv[1]
    lo = int(sys.argv[2]) if len(sys.argv) > 3 else 0
    hi = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << 62
    cur = None
    n = 0
    for ln in open(fn, errors='replace'):
        m = re.match(r'\s*(\d+)\.(\d+)\s+([SCBU])\s+dev=(\d+)\s+ep=(\w+)\s+xfer=(\d+)\s+len_urb=(\d+)\s+cap=(\d+)\s+st=(-?\d+)(.*)', ln)
        if m:
            ts = int(m.group(1)); typ = m.group(3)
            sm = re.search(r'setup ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{4}) ([0-9a-f]{4}) ([0-9a-f]{4})', m.group(10))
            if typ == 'S' and sm:
                if ts < lo or ts > hi:
                    cur = None; continue
                cur = dict(ts=ts, b8=sm.group(1), rq=sm.group(2), v=int(sm.group(3), 16),
                           ix=int(sm.group(4), 16), wl=int(sm.group(5), 16), data=None,
                           ep=m.group(6), st=m.group(9))
            elif typ == 'C':
                if cur is not None:
                    emit(cur); n += 1; cur = None
        elif ln.strip().startswith('data:') and cur is not None:
            cur['data'] = bytes.fromhex(ln.split('data:')[1].strip())
    if cur is not None:
        emit(cur); n += 1
    print("# %d transactions" % n, file=sys.stderr)

def emit(e):
    rq = e['rq']; d = e['data']
    tag = RQ.get(rq, 'RQ_' + rq)
    pre = "%10d %s b8=0x%s v=%04x ix=%04x wl=%d" % (e['ts'], tag, e['b8'], e['v'], e['ix'], e['wl'])
    if rq == '03' and d and len(d) >= 2:
        print("%s  W addr8=0x%02x i2c=[%s]   %s" % (pre, d[1], hx(d[2:]), classify_i2c(d[1], d[2:])))
    elif rq == '02':
        txlen = (e['v'] >> 8) & 0xff
        addr8 = e['v'] & 0xff
        regph = b''
        if txlen >= 1: regph += bytes([(e['ix'] >> 8) & 0xff])
        if txlen >= 2: regph += bytes([e['ix'] & 0xff])
        print("%s  R addr8=0x%02x regphase=[%s] -> [%s]  %s" % (
            pre, addr8, hx(regph), hx(d) if d else '-',
            classify_i2c(addr8, regph + d) if d else ''))
    elif rq == '13' and d and len(d) >= 4:
        print("%s  W(new) addr8=0x%02x flags=%02x bus=%02x i2c=[%s]   %s" % (
            pre, d[1], d[2], d[3], hx(d[4:]), classify_i2c(d[1], d[4:])))
    elif rq == '12':
        print("%s  R(new) addr8=%02x flags=%02x bus=%02x -> [%s]" % (
            pre, e['v'] & 0xff, (e['v'] >> 8) & 0xff, e['ix'], hx(d) if d else '-'))
    else:
        print("%s  data=[%s]" % (pre, hx(d) if d else '-'))

main()
