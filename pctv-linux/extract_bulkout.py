import sys, re
lines = open(sys.argv[1]).read().split('\n')
lo, hi = (int(sys.argv[2]), int(sys.argv[3])) if len(sys.argv) > 3 else (0, 99999999999)
cur = None; out = []
for ln in lines:
    m = re.match(r'\s*(\d+)\.\d+\s+([SC])\s+dev=(\d+)\s+ep=(\w+)\s+xfer=(\d+)', ln)
    if m:
        ts, typ, dev, ep, xfer = m.groups()
        ts = int(ts)
        if typ == 'S' and ep == '01' and xfer == '3' and lo <= ts <= hi:
            cur = {'ts': ts, 'data': None}
        elif typ == 'C':
            if cur: out.append(cur); cur = None
    elif ln.strip().startswith('data:') and cur is not None:
        cur['data'] = ln.split('data:')[1].strip()
prev = None
n = 0
for e in out:
    if not e['data']: continue
    n += 1
    if e['data'] == prev: continue
    prev = e['data']
    print(e['data'])
print("# total bulk OUT transfers: %d, unique-consecutive: %d" % (n, len([1 for e in out if e['data']])), file=sys.stderr)
