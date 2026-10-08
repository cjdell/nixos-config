using System;
using System.Text;
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
[ComImport, Guid("C6E13370-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAMCrossbar {
    [PreserveSig] int get_PinCounts(out int o, out int i);
    [PreserveSig] int get_CanRoute(int o, int i, out int can);
    [PreserveSig] int get_IsRoutedTo(int o, out int i);
    [PreserveSig] int get_CrossbarPinInfo(int isInputPin, int pinIndex, out int related, out int physType);
    [PreserveSig] int Route(int o, int i);
}
[ComImport, Guid("28F54685-06FD-11D2-B27A-00A0C9223196"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IKsControl { [PreserveSig] int KsProperty(ref KSIDENTIFIER p, int ps, IntPtr d, int ds, out int b); [PreserveSig] int KsMethod(ref KSIDENTIFIER p, int ps, IntPtr d, int ds, out int b); [PreserveSig] int KsEvent(ref KSIDENTIFIER p, int ps, IntPtr d, int ds, out int b); }
[StructLayout(LayoutKind.Sequential)]
struct KSIDENTIFIER { public Guid Set; public int Id; public int Flags; }
[ComImport, Guid("31EFAC30-515C-11d0-A9AA-00AA0061BE93"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IKsPropertySet { [PreserveSig] int QuerySupported(ref Guid s, int id, out int sup); [PreserveSig] int Get(ref Guid s, int id, IntPtr i, int ci, IntPtr d, int cd, out int r); [PreserveSig] int Set(ref Guid s, int id, IntPtr i, int ci, IntPtr d, int cd); }

// IPropertyPage host
[StructLayout(LayoutKind.Sequential)]
struct PROPPAGEINFO { public int cb; public IntPtr pszTitle; public int cx, cy; public IntPtr pszDocString; public IntPtr pszHelpFile; public int dwHelpContext; }
[StructLayout(LayoutKind.Sequential)]
struct SIZE { public int cx, cy; }
[StructLayout(LayoutKind.Sequential)]
struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)]
struct CAUUID { public int cElems; public IntPtr pElems; }
[ComImport, Guid("B196B28B-BAB4-101A-B69C-00AA00341D07"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISpecifyPropertyPages { [PreserveSig] int GetPages(out CAUUID p); }
[ComImport, Guid("B196B28F-BAB4-101A-B69C-00AA00341D07"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyPage {
    [PreserveSig] int SetPageSite(IntPtr site);
    [PreserveSig] int Activate(IntPtr hwndParent, ref RECT rc, int modal);
    [PreserveSig] int Deactivate();
    [PreserveSig] int GetPageInfo(IntPtr info);
    [PreserveSig] int SetObjects(uint c, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] IntPtr[] objs);
    [PreserveSig] int Show(uint cmd);
    [PreserveSig] int Move(ref RECT rc);
    [PreserveSig] int IsPageDirty();
    [PreserveSig] int Apply();
    [PreserveSig] int Help([MarshalAs(UnmanagedType.LPWStr)] string helpDir);
}

class Probe {
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wp, StringBuilder lp);
    [DllImport("ole32.dll")] static extern int OleInitialize(IntPtr p);
    [DllImport("user32.dll")] static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);

    const int CB_GETCOUNT=0x146, CB_GETCURSEL=0x147, CB_SETCURSEL=0x14E, CB_GETLBTEXT=0x148, CB_GETLBTEXTLEN=0x149, WM_COMMAND=0x111, CBN_SELCHANGE=1;

    static IEnumMoniker EnumCat(string g) {
        Guid cat=new Guid(g); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; int hr=de.CreateClassEnumerator(ref cat,out em,0); return hr==0?em:null;
    }
    static string Name(IMoniker m){ try{object b;Guid bid=typeof(IPropertyBag).GUID;m.BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);Marshal.ReleaseComObject(b);return Convert.ToString(v);}catch{return "<unnamed>";} }

    static string TryQI(object o, string label, Guid iid) {
        IntPtr p = Marshal.GetIUnknownForObject(o); IntPtr q; int hr = Marshal.QueryInterface(p, ref iid, out q);
        Marshal.Release(p);
        if (hr==0) { Marshal.Release(q); return "YES"; }
        return "no(0x"+hr.ToString("x8")+")";
    }

    static string Phys(int t){ string[] v={"Unknown","Video_Tuner","Video_Composite","Video_SVideo","Video_RGB"}; return t<5?v[t]:"type_"+t; }

    static void DumpFilter(string cat, IMoniker m) {
        string nm = Name(m);
        Guid ibf=typeof(IBaseFilter).GUID; object fobj;
        try { m.BindToObject(null,null,ref ibf,out fobj); } catch (Exception ex) { Console.WriteLine(cat+" "+nm+": bind fail "+ex.Message); return; }
        Console.Write("["+cat+"] '"+nm+"'");
        Guid gXbar=new Guid("C6E13370-30AC-11d0-A18C-00A0C9118956");
        Guid gKsC=new Guid("28F54685-06FD-11D2-B27A-00A0C9223196");
        Guid gKsP=new Guid("31EFAC30-515C-11d0-A9AA-00AA0061BE93");
        Guid gTuner=new Guid("211A8761-03AC-11D1-8D13-00AA00BDCDFD");
        Guid gAudMix=new Guid("A2C8DF83-A4EB-4A8F-AF0E-F1B5C46F5EBA".Replace("A2C8DF83","A2C8DF83"));
        Console.Write("  IAMCrossbar="+TryQI(fobj,"",gXbar));
        Console.Write(" IKsControl="+TryQI(fobj,"",gKsC));
        Console.Write(" IKsPropertySet="+TryQI(fobj,"",gKsP));
        Console.Write(" IAMTVTuner="+TryQI(fobj,"",gTuner));
        Console.WriteLine();
        if (TryQI(fobj,"",gXbar)=="YES") {
            IAMCrossbar cb=(IAMCrossbar)fobj;
            int oc,ic; cb.get_PinCounts(out oc,out ic);
            Console.WriteLine("    XBAR outputs="+oc+" inputs="+ic);
            for(int i=0;i<ic;i++){int rel,pt;cb.get_CrossbarPinInfo(1,i,out rel,out pt);Console.WriteLine("      IN["+i+"]="+Phys(pt));}
            for(int i=0;i<oc;i++){int r=-1;cb.get_IsRoutedTo(i,out r);Console.WriteLine("      OUT["+i+"] currently<-IN["+r+"]");}
        }
        IBaseFilter f=(IBaseFilter)fobj;
        IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while (ep.Next(1,ps,out got)==0 && got==1) {
            PIN_INFO pi; ps[0].QueryPinInfo(out pi);
            int dir; ps[0].QueryDirection(out dir);
            Console.Write("    pin '"+pi.name+"' dir="+(dir==0?"IN":"OUT")+" xbar="+TryQI(ps[0],"",gXbar)+" ksc="+TryQI(ps[0],"",gKsC)+" ksp="+TryQI(ps[0],"",gKsP));
            Console.WriteLine();
            Marshal.ReleaseComObject(ps[0]);
        }
        Marshal.ReleaseComObject(fobj);
    }

    static void HostPage(object fobj) {
        Console.WriteLine();
        Console.WriteLine("=== property page host ===");
        ISpecifyPropertyPages sp;
        try { sp=(ISpecifyPropertyPages)fobj; } catch { Console.WriteLine("no ISpecifyPropertyPages"); return; }
        CAUUID c; sp.GetPages(out c);
        Console.WriteLine("pages="+c.cElems);
        for (int i=0;i<c.cElems;i++) {
            Guid pg=(Guid)Marshal.PtrToStructure(new IntPtr(c.pElems.ToInt64()+i*16), typeof(Guid));
            Console.WriteLine(" page "+pg);
            object page=null;
            try { page=Activator.CreateInstance(Type.GetTypeFromCLSID(pg)); } catch(Exception ex){Console.WriteLine("   CoCreate fail: "+ex.Message);continue;}
            IPropertyPage pp=null;
            try { pp=(IPropertyPage)page; } catch(Exception ex){Console.WriteLine("   no IPropertyPage: "+ex.Message);continue;}
            IntPtr info=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(PROPPAGEINFO)));
            int hr=pp.GetPageInfo(info);
            PROPPAGEINFO pi=(PROPPAGEINFO)Marshal.PtrToStructure(info,typeof(PROPPAGEINFO));
            Console.WriteLine("   GetPageInfo hr=0x"+hr.ToString("x8")+" title='"+(pi.pszTitle!=IntPtr.Zero?Marshal.PtrToStringUni(pi.pszTitle):"?")+"' size="+pi.cx+"x"+pi.cy);
            int ws=unchecked((int)0x80000000)|0x10000000;
            IntPtr parent=CreateWindowEx(0,"#32770","pctvpage",ws,0,0,600,500,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
            if (parent==IntPtr.Zero) parent=CreateWindowEx(0,"Static","pctvpage",unchecked((int)0x80000000),0,0,600,500,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
            pp.SetPageSite(IntPtr.Zero);
            IntPtr unk=Marshal.GetIUnknownForObject(fobj);
            hr=pp.SetObjects(1,new IntPtr[]{unk});
            Console.WriteLine("   SetObjects hr=0x"+hr.ToString("x8"));
            RECT rc; rc.l=0;rc.t=0;rc.r=pi.cx>0?pi.cx:400;rc.b=pi.cy>0?pi.cy:300;
            hr=pp.Activate(parent, ref rc, 0);
            Console.WriteLine("   Activate hwnd="+parent+" hr=0x"+hr.ToString("x8"));
            int idx=0;
            EnumChildWindows(parent, delegate(IntPtr h, IntPtr l){
                StringBuilder cls=new StringBuilder(256); GetClassName(h,cls,256);
                StringBuilder txt=new StringBuilder(512); GetWindowText(h,txt,512);
                string cn=cls.ToString();
                string extra="";
                if (cn=="ComboBox") {
                    int n=(int)SendMessage(h,CB_GETCOUNT,IntPtr.Zero,IntPtr.Zero);
                    int cur=(int)SendMessage(h,CB_GETCURSEL,IntPtr.Zero,IntPtr.Zero);
                    extra=" items="+n+" cur="+cur;
                    for(int j=0;j<n;j++){ int len=(int)SendMessage(h,CB_GETLBTEXTLEN,(IntPtr)j,IntPtr.Zero); StringBuilder sb=new StringBuilder(len+2); SendMessage(h,CB_GETLBTEXT,(IntPtr)j,sb); extra+="\n        ["+j+"] '"+sb.ToString()+"'"; }
                }
                Console.WriteLine("   ctl#"+idx+" hwnd="+h+" class='"+cn+"' text='"+txt.ToString()+"'"+extra);
                idx++;
                return true;
            }, IntPtr.Zero);
            Console.WriteLine("   Controls found: "+idx);
            // try selecting SVideo/composite automatically
            IntPtr target=IntPtr.Zero; int targetItem=-1;
            EnumChildWindows(parent, delegate(IntPtr h, IntPtr l){
                StringBuilder cls=new StringBuilder(256); GetClassName(h,cls,256);
                if (cls.ToString()!="ComboBox") return true;
                int n=(int)SendMessage(h,CB_GETCOUNT,IntPtr.Zero,IntPtr.Zero);
                for(int j=0;j<n;j++){ int len=(int)SendMessage(h,CB_GETLBTEXTLEN,(IntPtr)j,IntPtr.Zero); StringBuilder sb=new StringBuilder(len+2); SendMessage(h,CB_GETLBTEXT,(IntPtr)j,sb);
                    string s=sb.ToString().ToLower();
                    if (s.Contains("svideo")||s.Contains("s-video")) { target=h; targetItem=j; Console.WriteLine("   -> would select SVideo item "+j+" on "+h); }
                    if (target==IntPtr.Zero && s.Contains("composite")) { target=h; targetItem=j; Console.WriteLine("   -> would select Composite item "+j+" on "+h); }
                }
                return true;
            }, IntPtr.Zero);
            if (target!=IntPtr.Zero) {
                SendMessage(target, CB_SETCURSEL, (IntPtr)targetItem, IntPtr.Zero);
                SendMessage(target, WM_COMMAND, (IntPtr)((CBN_SELCHANGE<<16)|1), target);
            }
            hr=pp.IsPageDirty();
            Console.WriteLine("   IsPageDirty hr=0x"+hr.ToString("x8")+" (1=dirty 0=clean)");
            hr=pp.Apply();
            Console.WriteLine("   Apply hr=0x"+hr.ToString("x8"));
            pp.Deactivate();
            if (parent!=IntPtr.Zero) DestroyWindow(parent);
            Marshal.ReleaseComObject(page);
        }
    }

    [STAThread]
    static void Main(string[] args) {
        OleInitialize(IntPtr.Zero);
        string[][] cats = new string[][] {
            new string[]{"CAPTURE","65E8773D-8F56-11D0-A3B9-00A0C9223196"},
            new string[]{"TVTUNER","A799A800-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"CROSSBAR","A799A801-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"TVAUDIO","A799A802-A46D-11D0-A18C-00A02401DCD4"},
            new string[]{"VIDIN","860BB310-5D01-11d0-BD3B-00A0C911CE86"},
            new string[]{"AUDIN","33D9A762-90C8-11d0-BD43-00A0C911CE86"},
        };
        object xbarObj=null;
        foreach (string[] c in cats) {
            IEnumMoniker em=EnumCat(c[1]); if (em==null) { Console.WriteLine("["+c[0]+"] no category"); continue; }
            IMoniker[] m=new IMoniker[1];
            while (em.Next(1,m,IntPtr.Zero)==0) {
                string nm=Name(m[0]);
                if (nm.ToLower().IndexOf("pctv")>=0) {
                    DumpFilter(c[0], m[0]);
                    if (xbarObj==null && c[0]=="CROSSBAR") { Guid ibf=typeof(IBaseFilter).GUID; object fo; m[0].BindToObject(null,null,ref ibf,out fo); xbarObj=fo; }
                }
                Marshal.ReleaseComObject(m[0]);
            }
        }
        if (xbarObj!=null && args.Length>0 && args[0]=="page") HostPage(xbarObj);
    }
}
