using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class Ksx {
    [ComImport, Guid("31EFAC30-515C-11d0-A9AA-00AA0061BE93"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IKsPropertySet { [PreserveSig] int QuerySupported(ref Guid s, int id, out int sup); [PreserveSig] int Get(ref Guid s, int id, IntPtr i, int ci, IntPtr d, int cd, out int r); [PreserveSig] int Set(ref Guid s, int id, IntPtr i, int ci, IntPtr d, int cd); }
    [StructLayout(LayoutKind.Sequential)] struct KSI { public Guid Set; public int Id; public int Flags; }
    [ComImport, Guid("28F54685-06FD-11D2-B27A-00A0C9223196"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IKsControl { [PreserveSig] int KsProperty(ref KSI p, int ps, IntPtr d, int ds, out int b); [PreserveSig] int KsMethod(ref KSI p, int ps, IntPtr d, int ds, out int b); [PreserveSig] int KsEvent(ref KSI p, int ps, IntPtr d, int ds, out int b); }

    static IMoniker FindPctv(string catGuid){
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if(de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while(em.Next(1,m,IntPtr.Zero)==0){ string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0) return m[0]; Marshal.ReleaseComObject(m[0]); }
        return null;
    }
    static IBaseFilter Bind(IMoniker m){ Guid ibf=typeof(IBaseFilter).GUID; object o=null; m.BindToObject(null,null,ref ibf,out o); return (IBaseFilter)o; }
    static IPin[] Pins(IBaseFilter f){ IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[32]; int got; var list=new System.Collections.Generic.List<IPin>();
        while(ep.Next(1,ps,out got)==0&&got==1){ list.Add(ps[0]); } return list.ToArray(); }
    static PIN_INFO Info(IPin p){ PIN_INFO pi; p.QueryPinInfo(out pi); return pi; }

    static void Probe(object o,string tag){
        GUIDs: ;
        IKsPropertySet ksp=null; try{ksp=(IKsPropertySet)o;}catch{}
        IKsControl ksc=null; try{ksc=(IKsControl)o;}catch{}
        Console.WriteLine("== "+tag+"  IKsPropertySet="+(ksp!=null)+" IKsControl="+(ksc!=null));
        System.Guid[] sets = {
            new Guid("6E8D4A20-310C-11D0-B79A-00AA003767A7"),
            new Guid("8C134960-51AD-11CF-878A-94F801C10000"),
            new Guid("1BD0ECB0-F8E2-11CE-AAC6-0020AF0B99A3"),
            new Guid("720D4AC0-3B0F-11D0-9A9C-00A0C9223196"),
            new Guid("D16E9E90-A242-11D0-8C4E-00A0C9223196"),
            new Guid("E1C4FD00-F03A-11D0-8E50-00A0C9223196"),
            new Guid("C6E13380-30AC-11d0-A18C-00A0C9118956"),
            new Guid("C6E13360-30AC-11d0-A18C-00A0C9118956"),
            new Guid("C6E13350-30AC-11d0-A18C-00A0C9118956"),
            new Guid("C6E13370-30AC-11d0-A18C-00A0C9118956"),
        };
        string[] nm={"Crossbar","Pin","Connection","Topology","BdaTopology?","?","?","?","DecoderPage","XbarPage"};
        if(ksp!=null){
            for(int s=0;s<sets.Length;s++){
                for(int id=0;id<5;id++){
                    int sup; int hr=ksp.QuerySupported(ref sets[s],id,out sup);
                    if(hr==0 && sup!=0) Console.WriteLine("   IKsPropertySet "+nm[s]+" id="+id+" sup="+sup);
                }
            }
        }
        if(ksc!=null){
            for(int s=0;s<sets.Length;s++){
                for(int id=0;id<5;id++){
                    for(int fl=0;fl<8;fl++){
                        KSI k=new KSI(); k.Set=sets[s]; k.Id=id; k.Flags=(fl&1)!=0?1:0; // GET only
                    }
                    IntPtr b=Marshal.AllocHGlobal(64); int got;
                    KSI kk=new KSI(); kk.Set=sets[s]; kk.Id=id; kk.Flags=1;
                    int hr=ksc.KsProperty(ref kk,Marshal.SizeOf(typeof(KSI)),b,64,out got);
                    if(hr==0) Console.WriteLine("   IKsControl GET "+nm[s]+" id="+id+" hr=0 got="+got);
                    Marshal.FreeHGlobal(b);
                }
            }
        }
    }

    [STAThread]
    static void Main(){
        IBaseFilter xbar=Bind(FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4"));
        IBaseFilter cap=Bind(FindPctv("65E8773D-8F56-11D0-A3B9-00A0C9223196"));
        Probe(xbar,"XBAR filter");
        foreach(IPin p in Pins(xbar)) Probe(p,"XBAR pin '"+Info(p).name+"'");
        Probe(cap,"CAP filter");
        foreach(IPin p in Pins(cap)) Probe(p,"CAP pin '"+Info(p).name+"'");
    }
}
