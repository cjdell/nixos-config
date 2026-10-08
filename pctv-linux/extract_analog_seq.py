import sys, re
lines = open(sys.argv[1]).read().split('\n')
lo, hi = int(sys.argv[2]), int(sys.argv[3])
seq = []
cur = None
for ln in lines:
    m = re.match(r'\s*(\d+)\.\d+\s+([SC])\s+dev=(\d+)\s+ep=(\w+)\s+xfer=(\d+)\s+len_urb=(\d+)\s+cap=(\d+)\s+st=(-?\d+)(.*)', ln)
    if m:
        ts, typ, dev, ep, xfer, lu, cap, st, rest = m.groups()
        ts = int(ts)
        if ts < lo or ts > hi: cur = None; continue
        sm = re.search(r'setup ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{4}) ([0-9a-f]{4}) ([0-9a-f]{4})', rest)
        if typ == 'S' and sm:
            b8, breq, v, ix, wl = sm.groups()
            cur = dict(ts=ts, b8=b8, rq=breq, v=v, ix=ix, wl=wl, dev=dev, ep=ep)
        elif typ == 'C':
            if cur: cur['status'] = st; seq.append(cur); cur = None
        elif typ == 'S' and not sm:
            cur = dict(ts=ts, b8='-', rq='-', v='-', ix='-', wl='-', dev=dev, ep=ep)
    elif ln.strip().startswith('data:') and cur is not None:
        cur['data'] = ln.split('data:')[1].strip()
# summarise
writes = {}
reads = []
for e in seq:
    if e['b8'] in ('40','44') and e['rq'] == '03' and 'data' in e:
        d = bytes.fromhex(e['data'])
        if len(d) >= 6 and d[0] == 0x03:
            addr = d[1]; reg = (d[2]<<8)|d[3]; val = (d[4]<<8)|d[5]
            writes.setdefault((addr,reg), []).append(val)
for (addr,reg), vals in sorted(writes.items()):
    print("WRITE  i2c8=%02x (7bit %02x)  reg %4d (0x%04x) = %s%s" % (
        addr, addr>>1, reg, reg, ' '.join('%04x'%v for v in dict.fromkeys(vals)),
        '  (x%d)'%len(vals) if len(vals)>1 else ''))
print()
for e in seq:
    if e['b8'] in ('c0','c4') and e['rq'] == '02':
        v = int(e['v'],16); ix = int(e['ix'],16)
        txlen = (v>>8)&0xff
        addr8 = v & 0xff
        reg = ix if txlen>=3 else None
        reads.append((addr8, txlen, ix, e.get('status')))
seen=set()
for a,t,ix,st in reads:
    k=(a,t,ix)
    if k in seen: continue
    seen.add(k)
    print("READ   i2c8=%02x (7bit %02x) txlen=%d wIndex=0x%04x status=%s" % (a, a>>1, t, ix, st))
print("\ntotal control events in window:", len(seq))
