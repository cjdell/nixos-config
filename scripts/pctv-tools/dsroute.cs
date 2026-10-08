using System;
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
    [PreserveSig] int ConnectionMediaType(IntPtr mt); [PreserveSig] int QueryPinInfo(out PIN_INFO info);
    [PreserveSig] int QueryDirection(out int dir); [PreserveSig] int QueryId(out IntPtr id);
    [PreserveSig] int QueryAccept(IntPtr mt); [PreserveSig] int EnumMediaTypes(out IntPtr e);
    [PreserveSig] int QueryInternalConnections(IntPtr a, ref int n);
    [PreserveSig] int EndOfStream(); [PreserveSig] int BeginFlush(); [PreserveSig] int EndFlush();
    [PreserveSig] int NewSegment(long a, long b, double r);
}
[ComImport, Guid("56a86892-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IEnumPins {
    [PreserveSig] int Next(int celt, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] IPin[] pins, out int fetched);
    [PreserveSig] int Skip(int c); [PreserveSig] int Reset(); [PreserveSig] int Clone(out IEnumPins e);
}
[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IBaseFilter {
    [PreserveSig] int GetClassID(out Guid g); [PreserveSig] int Stop(); [PreserveSig] int Pause();
    [PreserveSig] int Run(long t); [PreserveSig] int GetState(int ms, out int st);
    [PreserveSig] int SetSyncSource(IntPtr c); [PreserveSig] int GetSyncSource(out IntPtr c);
    [PreserveSig] int EnumPins(out IEnumPins e); [PreserveSig] int FindPin([MarshalAs(UnmanagedType.LPWStr)] string id, out IPin p);
    [PreserveSig] int QueryFilterInfo(IntPtr i); [PreserveSig] int JoinFilterGraph(IntPtr g, [MarshalAs(UnmanagedType.LPWStr)] string n);
    [PreserveSig] int QueryVendorInfo(out IntPtr n);
}
[StructLayout(LayoutKind.Sequential)]
struct KSIDENTIFIER { public Guid Set; public int Id; public int Flags; }
[ComImport, Guid("28F54685-06FD-11D2-B27A-00A0C9223196"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IKsControl {
    [PreserveSig] int KsProperty(ref KSIDENTIFIER p, int propSize, IntPtr data, int dataSize, out int bytes);
    [PreserveSig] int KsMethod(ref KSIDENTIFIER p, int methSize, IntPtr data, int dataSize, out int bytes);
    [PreserveSig] int KsEvent(ref KSIDENTIFIER p, int evtSize, IntPtr data, int dataSize, out int bytes);
}

class DSRoute {
    static Guid XBAR = new Guid("6E8D4A20-310C-11D0-B79A-00AA003767A7");
    const int GET = 1, SET = 2;
    static IEnumMoniker EnumCat(string g) {
        Guid cat=new Guid(g); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; int hr=de.CreateClassEnumerator(ref cat,out em,0); return hr==0?em:null;
    }
    static string Name(IMoniker m){ try{object b;Guid bid=typeof(IPropertyBag).GUID;m.BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);Marshal.ReleaseComObject(b);return Convert.ToString(v);}catch{return "<unnamed>";} }
    static int Prop(IKsControl ks, int id, int flags, IntPtr data, int len, out int bytes) {
        KSIDENTIFIER k = new KSIDENTIFIER(); k.Set = XBAR; k.Id = id; k.Flags = flags;
        return ks.KsProperty(ref k, Marshal.SizeOf(typeof(KSIDENTIFIER)), data, len, out bytes);
    }
    static void Dump(IKsControl ks, string where) {
        IntPtr b = Marshal.AllocHGlobal(64); int bytes;
        int hr = Prop(ks, 0, GET, b, 8, out bytes);
        if (hr != 0) { Console.WriteLine("  " + where + ": CAPS hr=0x" + hr.ToString("x8")); Marshal.FreeHGlobal(b); return; }
        int ni = Marshal.ReadInt32(b,0), no = Marshal.ReadInt32(b,4);
        Console.WriteLine("  " + where + ": CROSSBAR caps -> inputs=" + ni + " outputs=" + no);
        for (int i = 0; i < ni; i++) {
            Marshal.WriteInt32(b,0,1); Marshal.WriteInt32(b,4,i); Marshal.WriteInt32(b,8,0); Marshal.WriteInt32(b,12,0);
            hr = Prop(ks, 1, GET, b, 16, out bytes);
            if (hr==0) Console.WriteLine("     IN["+i+"] physType=" + Marshal.ReadInt32(b,12) + " related=" + Marshal.ReadInt32(b,8));
            else Console.WriteLine("     IN["+i+"] PININFO hr=0x"+hr.ToString("x8"));
        }
        for (int i = 0; i < no; i++) {
            Marshal.WriteInt32(b,0,0); Marshal.WriteInt32(b,4,i); Marshal.WriteInt32(b,8,0); Marshal.WriteInt32(b,12,0);
            hr = Prop(ks, 1, GET, b, 16, out bytes);
            if (hr==0) Console.WriteLine("     OUT["+i+"] physType=" + Marshal.ReadInt32(b,12) + " related=" + Marshal.ReadInt32(b,8));
        }
        Marshal.FreeHGlobal(b);
    }
    static void TryRoute(IKsControl ks, int outIdx, int inIdx) {
        IntPtr b = Marshal.AllocHGlobal(8); Marshal.WriteInt32(b,0,outIdx); Marshal.WriteInt32(b,4,inIdx);
        int bytes; int hr = Prop(ks, 3, SET, b, 8, out bytes);
        Console.WriteLine("  ROUTE OUT["+outIdx+"] <- IN["+inIdx+"] : hr=0x"+hr.ToString("x8"));
        Marshal.FreeHGlobal(b);
    }
    static void Main(string[] args) {
        IEnumMoniker em=EnumCat("A799A801-A46D-11D0-A18C-00A02401DCD4"); if (em==null){Console.WriteLine("no xbar cat");return;}
        IMoniker[] m=new IMoniker[1];
        while (em.Next(1,m,IntPtr.Zero)==0) {
            string nm=Name(m[0]);
            if (nm.ToLower().IndexOf("pctv")<0) { Marshal.ReleaseComObject(m[0]); continue; }
            Console.WriteLine("Filter: "+nm);
            Guid ibf=typeof(IBaseFilter).GUID; object fobj; m[0].BindToObject(null,null,ref ibf,out fobj);
            IBaseFilter f=(IBaseFilter)fobj;
            IKsControl ksf=null; try { ksf=(IKsControl)fobj; } catch {}
            if (ksf!=null) Dump(ksf,"filter");
            IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
            while (ep.Next(1,ps,out got)==0 && got==1) {
                PIN_INFO pi; ps[0].QueryPinInfo(out pi);
                IKsControl ksp=null; try { ksp=(IKsControl)(object)ps[0]; } catch {}
                if (ksp!=null) {
                    Console.WriteLine(" pin '"+pi.name+"' has IKsControl");
                    Dump(ksp,"pin '"+pi.name+"'");
                    if (args.Length>=2 && args[0]=="route") TryRoute(ksp, int.Parse(args[1]), int.Parse(args[2]));
                }
                Marshal.ReleaseComObject(ps[0]);
            }
            Marshal.ReleaseComObject(m[0]);
        }
    }
}
