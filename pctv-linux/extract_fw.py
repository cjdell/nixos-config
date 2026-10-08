import sys, struct
d=open('/tmp/pctv/mon.txt','rb').read()
HDR=48
i=0; out=[]; n=0
while i+HDR<=len(d):
    p=d[i:i+HDR]
    (ident,typ,xftype,epnum,devnum,busnum,fsetup,fdata,ts_sec,ts_usec,status,len_urb,len_cap)=struct.unpack_from('<QBBBBHbbqiiII',p,0)
    setup=p[40:48]
    data=b''
    if len_cap>0 and len_cap<8192:
        data=d[i+HDR:i+HDR+len_cap]; i+=HDR+len_cap
    else: i+=HDR
    if typ==ord('S') and epnum==0x01:
        out.append(data); n+=1
blob=b''.join(out)
open('/tmp/pctv/win_fw.bin','wb').write(blob)
print("bulk OUT submissions:",n,"total bytes:",len(blob))
# parse records
pos=0; recs=0; types={}
while pos+5<=len(blob):
    ln=blob[pos]; typ=blob[pos+3]
    if pos+4+ln+1>len(blob): print("truncated at",pos); break
    chk=blob[pos+4+ln]
    s=(ln+blob[pos+1]+blob[pos+2]+typ+sum(blob[pos+4:pos+4+ln]))&0xff
    if s!=((-chk)&0xff): print("bad chk at",pos,hex(chk),hex(s))
    types[typ]=types.get(typ,0)+1
    pos+=4+ln+1; recs+=1
    if typ==0x01: print("EOF record at",pos); break
print("records:",recs,"types:",types,"consumed:",pos,"of",len(blob))
