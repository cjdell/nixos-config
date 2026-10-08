using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid pType, out IEnumMoniker ppEnumMoniker, int dwFlags); }
[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] out object v, IntPtr err); [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] ref object v); }
[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IBaseFilter { }
[ComImport, Guid("C6E13370-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAMCrossbar {
    [PreserveSig] int get_PinCounts(out int o, out int i);
    [PreserveSig] int get_CanRoute(int o, int i, out int can);
    [PreserveSig] int get_IsRoutedTo(int o, out int i);
    [PreserveSig] int get_CrossbarPinInfo(int isInputPin, int pinIndex, out int related, out int physType);
    [PreserveSig] int Route(int o, int i);
}
[ComImport, Guid("C6E13350-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAMAnalogVideoDecoder {
    [PreserveSig] int get_AvailableTVFormats(out int f);
    [PreserveSig] int put_TVFormat(int f);
    [PreserveSig] int get_TVFormat(out int f);
}
class DSProbe {
    static string Phys(int t) {
        if (t==1) return "Video_Tuner"; if (t==2) return "Video_Composite"; if (t==3) return "Video_SVideo";
        if (t==4) return "Video_RGB"; if (t==4096) return "Audio_Tuner"; if (t==4097) return "Audio_Line";
        if (t==4098) return "Audio_Mic"; if (t==4101) return "Audio_Aux";
        return "rawtype_"+t;
    }
    static IEnumMoniker EnumCat(string g) {
        Guid cat=new Guid(g); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; int hr=de.CreateClassEnumerator(ref cat,out em,0);
        return hr==0?em:null;
    }
    static string Name(IMoniker m){ try{object b;Guid bid=typeof(IPropertyBag).GUID;m.BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);Marshal.ReleaseComObject(b);return Convert.ToString(v);}catch{return "<unnamed>";} }
    static void Main() {
        string[][] cats = new string[][] {
            new string[]{"TVTUNER","A799A800-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"CROSSBAR","A799A801-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"TVAUDIO","A799A802-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"VIDEO","6994AD05-93EF-11D0-A3CC-00A0C9223196"},
            new string[]{"CAPTURE","65E8773D-8F56-11D0-A3B9-00A0C9223196"},
        };
        foreach (string[] c in cats) {
            IEnumMoniker em=EnumCat(c[1]);
            if (em==null) continue;
            IMoniker[] m=new IMoniker[1];
            while (em.Next(1,m,IntPtr.Zero)==0) {
                string nm=Name(m[0]);
                if (nm.ToLower().IndexOf("pctv")<0 && nm.ToLower().IndexOf("2304")<0) { Marshal.ReleaseComObject(m[0]); continue; }
                Console.WriteLine("["+c[0]+"] "+nm);
                try {
                    Guid ibf=typeof(IBaseFilter).GUID; object fobj; m[0].BindToObject(null,null,ref ibf,out fobj);
                    bool any=false;
                    try { IAMCrossbar cb=(IAMCrossbar)fobj; any=true; int oc,ic; cb.get_PinCounts(out oc,out ic);
                          Console.WriteLine("    IAMCrossbar: outputs="+oc+" inputs="+ic);
                          for(int i=0;i<oc;i++){int r=-1;cb.get_IsRoutedTo(i,out r);Console.WriteLine("      OUT["+i+"] <- IN["+r+"]");}
                          for(int i=0;i<ic;i++){int rel,pt;cb.get_CrossbarPinInfo(1,i,out rel,out pt);Console.WriteLine("      IN["+i+"]="+Phys(pt));}
                    } catch { }
                    try { IAMAnalogVideoDecoder d=(IAMAnalogVideoDecoder)fobj; any=true; int av,cur; d.get_AvailableTVFormats(out av); d.get_TVFormat(out cur);
                          Console.WriteLine("    Decoder: current=0x"+cur.ToString("x")+" avail=0x"+av.ToString("x")); } catch { }
                    if(!any) Console.WriteLine("    (no crossbar/decoder interfaces)");
                } catch(Exception ex){ Console.WriteLine("    bind fail: "+ex.Message); }
                Marshal.ReleaseComObject(m[0]);
            }
        }
    }
}
