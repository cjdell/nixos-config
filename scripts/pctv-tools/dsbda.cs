using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid pType, out IEnumMoniker ppEnumMoniker, int dwFlags); }
[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] out object v, IntPtr err); [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] ref object v); }
[StructLayout(LayoutKind.Sequential)]
struct CAUUID { public int cElems; public IntPtr pElems; }
[ComImport, Guid("B196B28B-BAB4-101A-B69C-00AA00341D07"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISpecifyPropertyPages { [PreserveSig] int GetPages(out CAUUID p); }
[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IBaseFilter { }
class DSBDA {
    static IEnumMoniker EnumCat(string g){ Guid c=new Guid(g); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86"))); ICreateDevEnum d=(ICreateDevEnum)o; IEnumMoniker e; return d.CreateClassEnumerator(ref c,out e,0)==0?e:null; }
    static string Name(IMoniker m){ try{object b;Guid bid=typeof(IPropertyBag).GUID;m.BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);Marshal.ReleaseComObject(b);return Convert.ToString(v);}catch{return "?";} }
    static void Main() {
        string[][] cats = new string[][] {
            new string[]{"TVTUNER","A799A800-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"CROSSBAR","A799A801-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"TVAUDIO","A799A802-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"CAPTURE","65E8773D-8F56-11D0-A3B9-00A0C9223196"},
        };
        Guid gTop = new Guid("79B56888-7FEA-4690-B45D-38FD3C7849BE");
        Guid gXbar = new Guid("C6E13370-30AC-11d0-A18C-00A0C9118956");
        foreach (string[] c in cats) {
            IEnumMoniker em=EnumCat(c[1]); if(em==null) continue;
            IMoniker[] m=new IMoniker[1];
            while (em.Next(1,m,IntPtr.Zero)==0) {
                string nm=Name(m[0]); if(nm.ToLower().IndexOf("pctv")<0){Marshal.ReleaseComObject(m[0]);continue;}
                Console.WriteLine("["+c[0]+"] "+nm);
                object fobj; Guid ibf=typeof(IBaseFilter).GUID; m[0].BindToObject(null,null,ref ibf,out fobj);
                IntPtr unk=Marshal.GetIUnknownForObject(fobj);
                IntPtr p;
                Console.WriteLine("   IBDA_Topology: "+(Marshal.QueryInterface(unk,ref gTop,out p)==0?"YES":"no"));
                if (p!=IntPtr.Zero) Marshal.Release(p);
                Console.WriteLine("   IAMCrossbar  : "+(Marshal.QueryInterface(unk,ref gXbar,out p)==0?"YES":"no"));
                if (p!=IntPtr.Zero) Marshal.Release(p);
                try {
                    ISpecifyPropertyPages sp=(ISpecifyPropertyPages)fobj; CAUUID cau; sp.GetPages(out cau);
                    Console.WriteLine("   PropertyPages: "+cau.cElems);
                    for (int i=0;i<cau.cElems;i++) { IntPtr g=Marshal.ReadIntPtr(cau.pElems, i*16); Console.WriteLine("      page "+i+": "+Marshal.PtrToStructure(g,typeof(Guid))); }
                } catch(Exception ex){ Console.WriteLine("   PropertyPages: none ("+ex.Message+")"); }
                Marshal.Release(unk);
                Marshal.ReleaseComObject(m[0]);
            }
        }
    }
}
