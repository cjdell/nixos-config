import sys, re
lines = open(sys.argv[1]).read().split('\n')
lo, hi = int(sys.argv[2]), int(sys.argv[3])
out = []
cur = None
for ln in lines:
    m = re.match(r'\s*(\d+)\.\d+\s+([SC])\s+dev=(\d+)\s+ep=(\w+)\s+xfer=(\d+)\s+len_urb=(\d+)\s+cap=(\d+)\s+st=(-?\d+)(.*)', ln)
    if m:
        ts, typ, dev, ep, xfer, lu, cap, st, rest = m.groups()
        ts = int(ts)
        if ts < lo or ts > hi: cur = None; continue
        sm = re.search(r'setup ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{4}) ([0-9a-f]{4}) ([0-9a-f]{4})', rest)
        if typ == 'S' and sm:
            cur = dict(b8=sm.group(1), rq=sm.group(2), v=sm.group(3), ix=sm.group(4), wl=sm.group(5), data=None)
        elif typ == 'C':
            if cur: out.append(cur); cur = None
    elif ln.strip().startswith('data:') and cur is not None:
        cur['data'] = ln.split('data:')[1].replace(' ', '')
prev = None
for e in out:
    key = (e['b8'], e['rq'], e['v'], e['ix'], e['wl'], e['data'])
    if key == prev: continue
    prev = key
    if e['rq'] == '03' and e['data']:
        d = bytes.fromhex(e['data'])
        if len(d) >= 6 and d[0] == 3:
            print("wr %02x %4d %4d" % (d[1], (d[2]<<8)|d[3], (d[4]<<8)|d[5]))
    elif e['rq'] == '0c' and e['data']:
        d = bytes.fromhex(e['data'])
        print("gpio %s" % ' '.join('%02x'%b for b in d))
    elif e['rq'] == '11':
        print("SETUP_DEMOD data=%s" % (e['data'] or '-'))
    elif e['rq'] == '02':
        v = int(e['v'],16); print("rd %02x %4d" % (v & 0xff, int(e['ix'],16)))
