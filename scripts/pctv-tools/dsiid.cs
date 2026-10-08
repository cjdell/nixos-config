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
class DSIID {
    static string[][] IIDS = new string[][] {
        new string[]{"IAMCrossbar","C6E13370-30AC-11d0-A18C-00A0C9118956"},
        new string[]{"IKsControl","28F54685-06FD-11D2-B27A-00A0C9223196"},
        new string[]{"IKsPropertySet","31EFAC30-515C-11d0-A9AA-00AA0061BE93"},
        new string[]{"IBDA_Topology","79EFC385-A3D3-4C51-9FB5-B3157B6A0D2C"},
        new string[]{"IBDA_DeviceControl","FD0A5AF3-B41D-11d2-9C95-00C04F7971E0"},
        new string[]{"IBDA_SignalStatistics","1347D106-CF3A-428a-A5CB-AC0D9A2A4338"},
        new string[]{"IAMTVTuner","211A8766-03AC-11D1-8D13-00AA00BD8339"},
        new string[]{"IAMTuner","211A8761-03AC-11D1-8D13-00AA00BD8339"},
        new string[]{"IAMAnalogVideoDecoder","C6E13350-30AC-11d0-A18C-00A0C9118956"},
        new string[]{"IAMVideoProcAmp","C6E13360-30AC-11d0-A18C-00A0C9118956"},
        new string[]{"ISpecifyPropertyPages","B196B28B-BAB4-101A-B69C-00AA00341D07"},
        new string[]{"IPersistStream","00000109-0000-0000-C000-000000000046"},
    };
    static IEnumMoniker EnumCat(string g) {
        Guid cat=new Guid(g); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; int hr=de.CreateClassEnumerator(ref cat,out em,0); return hr==0?em:null;
    }
    static string Name(IMoniker m){ try{object b;Guid bid=typeof(IPropertyBag).GUID;m.BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);Marshal.ReleaseComObject(b);return Convert.ToString(v);}catch{return "<unnamed>";} }
    static void Probe(object rcw, string label) {
        IntPtr unk = Marshal.GetIUnknownForObject(rcw);
        foreach (string[] t in IIDS) {
            Guid iid = new Guid(t[1]); IntPtr p;
            int hr = Marshal.QueryInterface(unk, ref iid, out p);
            if (hr == 0) { Console.WriteLine("      OK   " + t[0]); Marshal.Release(p); }
        }
        Marshal.Release(unk);
    }
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
                string nm=Name(m[0]); if (nm.ToLower().IndexOf("pctv")<0) { Marshal.ReleaseComObject(m[0]); continue; }
                Console.WriteLine("["+c[0]+"] "+nm);
                Guid ibf=typeof(IBaseFilter).GUID; object fobj; m[0].BindToObject(null,null,ref ibf,out fobj);
                Console.WriteLine("   FILTER interfaces:"); Probe(fobj, "filter");
                IBaseFilter f=(IBaseFilter)fobj; IEnumPins ep; f.EnumPins(out ep);
                IPin[] ps=new IPin[1]; int got;
                while (ep.Next(1,ps,out got)==0 && got==1) {
                    PIN_INFO pi; ps[0].QueryPinInfo(out pi);
                    Console.WriteLine("   PIN '"+pi.name+"':"); Probe((object)ps[0], pi.name);
                    Marshal.ReleaseComObject(ps[0]);
                }
                Marshal.ReleaseComObject(m[0]);
            }
        }
    }
}
