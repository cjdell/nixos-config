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
    [PreserveSig] int Connect(IPin r, IntPtr mt);
    [PreserveSig] int ReceiveConnection(IPin c, IntPtr mt);
    [PreserveSig] int Disconnect();
    [PreserveSig] int ConnectedTo(out IPin p);
    [PreserveSig] int ConnectionMediaType(IntPtr mt);
    [PreserveSig] int QueryPinInfo(out PIN_INFO info);
    [PreserveSig] int QueryDirection(out int dir);
    [PreserveSig] int QueryId(out IntPtr id);
    [PreserveSig] int QueryAccept(IntPtr mt);
    [PreserveSig] int EnumMediaTypes(out IntPtr e);
    [PreserveSig] int QueryInternalConnections(IntPtr a, ref int n);
    [PreserveSig] int EndOfStream();
    [PreserveSig] int BeginFlush();
    [PreserveSig] int EndFlush();
    [PreserveSig] int NewSegment(long a, long b, double r);
}
[ComImport, Guid("56a86892-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IEnumPins {
    [PreserveSig] int Next(int celt, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] IPin[] pins, out int fetched);
    [PreserveSig] int Skip(int c);
    [PreserveSig] int Reset();
    [PreserveSig] int Clone(out IEnumPins e);
}
[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IBaseFilter {
    [PreserveSig] int GetClassID(out Guid g);
    [PreserveSig] int Stop();
    [PreserveSig] int Pause();
    [PreserveSig] int Run(long t);
    [PreserveSig] int GetState(int ms, out int st);
    [PreserveSig] int SetSyncSource(IntPtr c);
    [PreserveSig] int GetSyncSource(out IntPtr c);
    [PreserveSig] int EnumPins(out IEnumPins e);
    [PreserveSig] int FindPin([MarshalAs(UnmanagedType.LPWStr)] string id, out IPin p);
    [PreserveSig] int QueryFilterInfo(IntPtr i);
    [PreserveSig] int JoinFilterGraph(IntPtr g, [MarshalAs(UnmanagedType.LPWStr)] string n);
    [PreserveSig] int QueryVendorInfo(out IntPtr n);
}

class DSTree {
    static IEnumMoniker EnumCat(string g) {
        Guid cat=new Guid(g); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; int hr=de.CreateClassEnumerator(ref cat,out em,0); return hr==0?em:null;
    }
    static string Name(IMoniker m){ try{object b;Guid bid=typeof(IPropertyBag).GUID;m.BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);Marshal.ReleaseComObject(b);return Convert.ToString(v);}catch{return "<unnamed>";} }
    static void Main() {
        string[][] cats = new string[][] {
            new string[]{"TVTUNER","A799A800-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"CROSSBAR","A799A801-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"TVAUDIO","A799A802-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"CAPTURE","65E8773D-8F56-11D0-A3B9-00A0C9223196"},
        };
        foreach (string[] c in cats) {
            IEnumMoniker em=EnumCat(c[1]); if (em==null) continue;
            IMoniker[] m=new IMoniker[1];
            while (em.Next(1,m,IntPtr.Zero)==0) {
                string nm=Name(m[0]);
                if (nm.ToLower().IndexOf("pctv")<0) { Marshal.ReleaseComObject(m[0]); continue; }
                Console.WriteLine("["+c[0]+"] "+nm);
                try {
                    Guid ibf=typeof(IBaseFilter).GUID; object fobj; m[0].BindToObject(null,null,ref ibf,out fobj);
                    IBaseFilter f=(IBaseFilter)fobj;
                    IEnumPins ep; f.EnumPins(out ep);
                    IPin[] ps=new IPin[1]; int got;
                    while (ep.Next(1,ps,out got)==0 && got==1) {
                        PIN_INFO pi; ps[0].QueryPinInfo(out pi);
                        int dir; ps[0].QueryDirection(out dir);
                        string conn="unconnected";
                        try { IPin other; if (ps[0].ConnectedTo(out other)==0 && other!=null) { PIN_INFO oi; other.QueryPinInfo(out oi); conn="-> "+oi.name; } } catch {}
                        Console.WriteLine("   pin '" + pi.name + "' dir=" + (dir==0?"INPUT":"OUTPUT") + "  " + conn);
                        Marshal.ReleaseComObject(ps[0]);
                    }
                    Marshal.ReleaseComObject(ep);
                } catch(Exception ex){ Console.WriteLine("   err: "+ex.Message); }
                Marshal.ReleaseComObject(m[0]);
            }
        }
    }
}
