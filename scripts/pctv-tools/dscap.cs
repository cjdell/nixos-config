using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid pType, out IEnumMoniker ppEnumMoniker, int dwFlags); }
[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] out object v, IntPtr err); [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] ref object v); }

[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
struct PIN_INFO { public IntPtr pFilter; public int dir; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string name; }
[ComImport, Guid("56a86891-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPin {
    [PreserveSig] int Connect(IPin r, IntPtr mt); [PreserveSig] int ReceiveConnection(IPin c, IntPtr mt);
    [PreserveSig] int Disconnect(); [PreserveSig] int ConnectedTo(out IPin p);
    [PreserveSig] int ConnectionMediaType(IntPtr mt); [PreserveSig] int QueryPinInfo(out PIN_INFO i);
    [PreserveSig] int QueryDirection(out int d); [PreserveSig] int QueryId(out IntPtr id);
    [PreserveSig] int QueryAccept(IntPtr mt); [PreserveSig] int EnumMediaTypes(out IntPtr e);
    [PreserveSig] int QueryInternalConnections(IntPtr a, ref int n);
    [PreserveSig] int EndOfStream(); [PreserveSig] int BeginFlush(); [PreserveSig] int EndFlush(); [PreserveSig] int NewSegment(long a, long b, double r);
}
[ComImport, Guid("56a86892-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IEnumPins { [PreserveSig] int Next(int c, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] IPin[] p, out int f); [PreserveSig] int Skip(int c); [PreserveSig] int Reset(); [PreserveSig] int Clone(out IEnumPins e); }
[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IBaseFilter {
    [PreserveSig] int GetClassID(out Guid g); [PreserveSig] int Stop(); [PreserveSig] int Pause(); [PreserveSig] int Run(long t);
    [PreserveSig] int GetState(int ms, out int st); [PreserveSig] int SetSyncSource(IntPtr c); [PreserveSig] int GetSyncSource(out IntPtr c);
    [PreserveSig] int EnumPins(out IEnumPins e); [PreserveSig] int FindPin([MarshalAs(UnmanagedType.LPWStr)] string id, out IPin p);
    [PreserveSig] int QueryFilterInfo(IntPtr i); [PreserveSig] int JoinFilterGraph(IntPtr g, [MarshalAs(UnmanagedType.LPWStr)] string n);
    [PreserveSig] int QueryVendorInfo(out IntPtr n);
}
[ComImport, Guid("56a868a9-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGraphBuilder {
    [PreserveSig] int AddFilter(IBaseFilter f, [MarshalAs(UnmanagedType.LPWStr)] string name);
    [PreserveSig] int RemoveFilter(IBaseFilter f);
    [PreserveSig] int EnumFilters(out IntPtr e);
    [PreserveSig] int FindFilterByName([MarshalAs(UnmanagedType.LPWStr)] string n, out IBaseFilter f);
    [PreserveSig] int ConnectDirect(IPin o, IPin i, IntPtr mt);
    [PreserveSig] int Reconnect(IPin p);
    [PreserveSig] int Disconnect(IPin p);
    [PreserveSig] int SetDefaultSyncSource();
    [PreserveSig] int Connect(IPin o, IPin i);
}
[ComImport, Guid("56a868b1-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMediaControl {
    [PreserveSig] int GetTypeInfoCount(out int c);
    [PreserveSig] int GetTypeInfo(int i, int lcid, out IntPtr ti);
    [PreserveSig] int GetIDsOfNames(ref Guid riid, [MarshalAs(UnmanagedType.LPArray, ArraySubType=UnmanagedType.LPWStr)] string[] names, int c, int lcid, [MarshalAs(UnmanagedType.LPArray)] int[] ids);
    [PreserveSig] int Invoke(int dispId, ref Guid riid, int lcid, short flags, IntPtr dp, IntPtr vr, IntPtr ei, IntPtr ae);
    [PreserveSig] int Run(); [PreserveSig] int Pause(); [PreserveSig] int Stop();
    [PreserveSig] int GetState(int ms, out int st);
}
[ComImport, Guid("31EFAC30-515C-11d0-A9AA-00AA0061BE93"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IKsPropertySet {
    [PreserveSig] int QuerySupported(ref Guid s, int id, out int sup);
    [PreserveSig] int Get(ref Guid s, int id, IntPtr inst, int cbInst, IntPtr data, int cbData, out int returned);
    [PreserveSig] int Set(ref Guid s, int id, IntPtr inst, int cbInst, IntPtr data, int cbData);
}
[ComImport, Guid("6B652FFF-11FE-4FCE-92AD-0266B5D7C78F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISampleGrabber {
    [PreserveSig] int SetOneShot([MarshalAs(UnmanagedType.Bool)] bool b);
    [PreserveSig] int SetMediaType(IntPtr mt);
    [PreserveSig] int GetConnectedMediaType(IntPtr mt);
    [PreserveSig] int SetBufferSamples([MarshalAs(UnmanagedType.Bool)] bool b);
    [PreserveSig] int GetCurrentBuffer(ref int size, IntPtr buf);
    [PreserveSig] int GetCurrentSample(out IntPtr s);
    [PreserveSig] int SetCallback(IntPtr cb, int m);
}
[StructLayout(LayoutKind.Sequential)]
struct AM_MEDIA_TYPE { public Guid majortype, subtype; public int fixedSize, temporal; public int sampleSize; public Guid formattype; public IntPtr pUnk; public int cbFormat; public IntPtr pbFormat; }
[StructLayout(LayoutKind.Sequential)]
struct RECT { public int left, top, right, bottom; }
[StructLayout(LayoutKind.Sequential)]
struct BITMAPINFOHEADER { public int biSize; public int biWidth; public int biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
[StructLayout(LayoutKind.Sequential)]
struct VIDEOINFOHEADER { public RECT rcSource, rcTarget; public int dwBitRate, dwBitErrorRate; public long AvgTimePerFrame; public BITMAPINFOHEADER bmiHeader; }

class DSCap {
    static IMoniker FindPctv(string catGuid) {
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if (de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while (em.Next(1,m,IntPtr.Zero)==0) {
            string nm="";
            try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if (nm.ToLower().IndexOf("pctv")>=0) return m[0];
            Marshal.ReleaseComObject(m[0]);
        }
        return null;
    }
    static IBaseFilter Bind(IMoniker m) { Guid ibf=typeof(IBaseFilter).GUID; object o; m.BindToObject(null,null,ref ibf,out o); if(o==null){Console.WriteLine("bind failed");return null;} return (IBaseFilter)o; }
    static IPin PinByName(IBaseFilter f, string name, int dir) {
        IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while (ep.Next(1,ps,out got)==0 && got==1) { PIN_INFO pi; ps[0].QueryPinInfo(out pi);
            if (pi.name==name) return ps[0]; Marshal.ReleaseComObject(ps[0]); }
        return null;
    }
    static IPin FirstPin(IBaseFilter f, int wantDir) {
        IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while (ep.Next(1,ps,out got)==0 && got==1) { int d; ps[0].QueryDirection(out d); if (d==wantDir) return ps[0]; Marshal.ReleaseComObject(ps[0]); }
        return null;
    }
    static void KsSet(IPin p, string label, int outIdx, int inIdx) {
        try {
            IKsPropertySet ks=(IKsPropertySet)(object)p;
            Guid set=new Guid("6E8D4A20-310C-11D0-B79A-00AA003767A7");
            int sup; int hr0=ks.QuerySupported(ref set,3,out sup);
            IntPtr b=Marshal.AllocHGlobal(8); Marshal.WriteInt32(b,0,outIdx); Marshal.WriteInt32(b,4,inIdx);
            int hr=ks.Set(ref set,3,IntPtr.Zero,0,b,8); Marshal.FreeHGlobal(b);
            Console.WriteLine("  KsPropertySet.Set(CROSSBAR_ROUTE "+outIdx+"<-"+inIdx+") on '"+label+"': supported=0x"+sup.ToString("x")+" hr=0x"+hr.ToString("x8"));
        } catch (Exception ex) { Console.WriteLine("  '"+label+"' no IKsPropertySet: "+ex.Message); }
    }
    static void Main(string[] args) {
        int outIdx = args.Length>=1?int.Parse(args[0]):0;
        int inIdx  = args.Length>=2?int.Parse(args[1]):1;
        string outFile = args.Length>=3?args[2]:"frame.raw";
        IMoniker xm=FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4");
        IMoniker cm=FindPctv("65E8773D-8F56-11D0-A3B9-00A0C9223196");
        IBaseFilter xbar=Bind(xm), cap=Bind(cm);
        object gObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("E436EBB3-524F-11CE-9F53-0020AF0BA770")));
        IGraphBuilder gb=(IGraphBuilder)gObj; IMediaControl mc=(IMediaControl)gObj;
        Console.WriteLine("AddFilter xbar hr=0x"+gb.AddFilter(xbar,"xbar").ToString("x8"));
        Console.WriteLine("AddFilter cap  hr=0x"+gb.AddFilter(cap,"cap").ToString("x8"));
        IPin xo=PinByName(xbar,"0: Video Decoder Out",1);
        IPin ci=PinByName(cap,"Analog Video In",0);
        Console.WriteLine("pins: xo="+(xo!=null)+" ci="+(ci!=null));
        if (xo==null||ci==null) return;
        int hc=gb.Connect(xo,ci); Console.WriteLine("Connect(xbar->cap) hr=0x"+hc.ToString("x8"));
        // route S-Video on every crossbar pin until one takes
        foreach (string pn in new string[]{"0: Video Decoder Out","1: Video SVideo In","0: Video Tuner In","2: Video Composite In"}) {
            IPin p=PinByName(xbar,pn,0); if(p!=null){ KsSet(p,pn,outIdx,inIdx); Marshal.ReleaseComObject(p);} 
        }
        // sample grabber + null renderer
        object sgObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A0-3F08-11D3-9F0B-006008039E37")));
        object nrObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A4-3F08-11D3-9F0B-006008039E37")));
        IBaseFilter sg=(IBaseFilter)sgObj, nr=(IBaseFilter)nrObj;
        Console.WriteLine("AddFilter sg hr=0x"+gb.AddFilter(sg,"sg").ToString("x8"));
        Console.WriteLine("AddFilter nr hr=0x"+gb.AddFilter(nr,"nr").ToString("x8"));
        IPin co=PinByName(cap,"Capture",1);
        IPin sgi=FirstPin(sg,0), sgo=FirstPin(sg,1), nri=FirstPin(nr,0);
        Console.WriteLine("Connect(cap->sg) hr=0x"+gb.Connect(co,sgi).ToString("x8"));
        Console.WriteLine("Connect(sg->nr)  hr=0x"+gb.Connect(sgo,nri).ToString("x8"));
        ISampleGrabber grab=(ISampleGrabber)sgObj;
        grab.SetBufferSamples(true); grab.SetOneShot(false);
        Console.WriteLine("Run hr=0x"+mc.Run().ToString("x8"));
        System.Threading.Thread.Sleep(5000);
        int sz=0; int gh=grab.GetCurrentBuffer(ref sz, IntPtr.Zero);
        Console.WriteLine("GetCurrentBuffer size query hr=0x"+gh.ToString("x8")+" size="+sz);
        IntPtr mtp=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(AM_MEDIA_TYPE)));
        int mh=grab.GetConnectedMediaType(mtp);
        AM_MEDIA_TYPE mt=(AM_MEDIA_TYPE)Marshal.PtrToStructure(mtp,typeof(AM_MEDIA_TYPE));
        int w=0,h=0,bits=0,comp=0;
        if (mt.pbFormat!=IntPtr.Zero) { VIDEOINFOHEADER vih=(VIDEOINFOHEADER)Marshal.PtrToStructure(mt.pbFormat,typeof(VIDEOINFOHEADER)); w=vih.bmiHeader.biWidth;h=vih.bmiHeader.biHeight;bits=vih.bmiHeader.biBitCount;comp=vih.bmiHeader.biCompression; }
        Console.WriteLine("MediaType subtype="+mt.subtype+" "+w+"x"+h+" bits="+bits+" comp="+comp+" cbFormat="+mt.cbFormat);
        if (sz>0) { IntPtr buf=Marshal.AllocHGlobal(sz); int g2=grab.GetCurrentBuffer(ref sz, buf);
            byte[] data=new byte[sz]; Marshal.Copy(buf,data,0,sz); File.WriteAllBytes(outFile,data);
            Console.WriteLine("wrote "+sz+" bytes to "+outFile+" hr=0x"+g2.ToString("x8")); Marshal.FreeHGlobal(buf); }
        else Console.WriteLine("!! no frame available");
        mc.Stop();
    }
}
