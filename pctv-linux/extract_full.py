import sys, re
lines = open(sys.argv[1]).read().split('\n')
lo, hi = int(sys.argv[2]), int(sys.argv[3])
ev = []
cur = None
for ln in lines:
    m = re.match(r'\s*(\d+)\.\d+\s+([SC])\s+dev=(\d+)\s+ep=(\w+)\s+xfer=(\d+)\s+len_urb=(\d+)\s+cap=(\d+)\s+st=(-?\d+)(.*)', ln)
    if m:
        ts, typ, dev, ep, xfer, lu, cap, st, rest = m.groups()
        ts = float(ln.strip().split()[0])
        if not (lo <= ts <= hi): cur = None; continue
        if typ == 'S':
            sm = re.search(r'setup ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{4}) ([0-9a-f]{4}) ([0-9a-f]{4})', rest)
            if sm:
                cur = {'k':'ctrl','b8':sm.group(1),'rq':sm.group(2),'v':sm.group(3),'ix':sm.group(4),'wl':sm.group(5),'data':None,'ts':ts}
            elif ep == '01' and xfer == '3':
                cur = {'k':'bulk','data':None,'ts':ts}
            else: cur = None
        elif typ == 'C':
            if cur: ev.append(cur); cur = None
    elif ln.strip().startswith('data:') and cur is not None:
        cur['data'] = ln.split('data:')[1].replace(' ','').strip()
prev = None
for e in ev:
    if e['k'] == 'bulk':
        if e['data']: print("bulk %s" % e['data'])
        continue
    if e['rq'] == '03' and e['data'] and len(e['data']) >= 12:
        d = bytes.fromhex(e['data'])
        print("wr %02x %d %d" % (d[1], (d[2]<<8)|d[3], (d[4]<<8)|d[5]))
    elif e['rq'] == '0c' and e['data']:
        print("gpio %s" % e['data'])
    elif e['rq'] == '11':
        print("SETUP_DEMOD data=%s" % (e['data'] or ''))
