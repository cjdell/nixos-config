using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid pType, out IEnumMoniker ppEnumMoniker, int dwFlags); }
[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] out object v, IntPtr err); [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] ref object v); }
[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IBaseFilter { }
[StructLayout(LayoutKind.Sequential)]
struct CAUUID { public int cElems; public IntPtr pElems; }
[ComImport, Guid("B196B28B-BAB4-101A-B69C-00AA00341D07"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISpecifyPropertyPages { [PreserveSig] int GetPages(out CAUUID p); }

class PageAuto {
    [DllImport("ole32.dll")] static extern int OleInitialize(IntPtr p);
    [DllImport("ole32.dll")] static extern void OleUninitialize();
    [DllImport("ole32.dll")] static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, int ctx, ref Guid iid, out IntPtr p);
    [DllImport("oleaut32.dll", CharSet=CharSet.Unicode)]
    static extern int OleCreatePropertyFrame(IntPtr hwndOwner, int x, int y, string caption, uint cObjects, IntPtr ppUnk, uint cPages, IntPtr lpPageClsID, int lcid, int dwReserved, IntPtr lpvReserved);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("kernel32.dll")] static extern int GetCurrentProcessId();
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wp, StringBuilder lp);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr wp, IntPtr lp);

    const int CB_GETCOUNT=0x146, CB_GETCURSEL=0x147, CB_GETLBTEXT=0x148, CB_GETLBTEXTLEN=0x149, BM_CLICK=0xF5, WM_COMMAND=0x111, WM_CLOSE=0x10;

    static string QI(IntPtr pUnk, string name, string iidStr) {
        Guid iid=new Guid(iidStr); IntPtr q;
        int hr=Marshal.QueryInterface(pUnk, ref iid, out q);
        if(hr==0) Marshal.Release(q);
        return name+"="+(hr==0?"YES":"no(0x"+hr.ToString("x8")+")");
    }

    static void DumpChildren(IntPtr parent, string tag) {
        int idx=0;
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l){
            StringBuilder cls=new StringBuilder(256); GetClassName(h,cls,256);
            StringBuilder txt=new StringBuilder(512); GetWindowText(h,txt,512);
            string cn=cls.ToString(); string ex="";
            if(cn=="ComboBox"){
                int n=(int)SendMessage(h,CB_GETCOUNT,IntPtr.Zero,IntPtr.Zero);
                int cur=(int)SendMessage(h,CB_GETCURSEL,IntPtr.Zero,IntPtr.Zero);
                ex=" COMBO items="+n+" cur="+cur;
                for(int j=0;j<n;j++){
                    int len=(int)SendMessage(h,CB_GETLBTEXTLEN,(IntPtr)j,IntPtr.Zero);
                    StringBuilder sb=new StringBuilder(len+2); SendMessage(h,CB_GETLBTEXT,(IntPtr)j,sb);
                    ex+="\n      ["+j+"] '"+sb.ToString()+"'";
                }
            }
            Console.WriteLine("  "+tag+" ctl#"+idx+" hwnd=0x"+h.ToString("x")+" class='"+cn+"' text='"+txt.ToString()+"'"+ex);
            idx++;
            return true;
        }, IntPtr.Zero);
        Console.WriteLine("  "+tag+" total children="+idx);
    }

    [STAThread]
    static void Main(string[] args) {
        OleInitialize(IntPtr.Zero);
        Console.WriteLine("process bits="+(IntPtr.Size*8));
        // find xbar filter
        Guid cat=new Guid("A799A801-A46D-11D0-A18C-00A02401DCD4");
        object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; de.CreateClassEnumerator(ref cat,out em,0);
        IMoniker[] m=new IMoniker[1]; object fobj=null;
        while(em.Next(1,m,IntPtr.Zero)==0){
            string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0){ Guid ibf=typeof(IBaseFilter).GUID; m[0].BindToObject(null,null,ref ibf,out fobj); break; }
            Marshal.ReleaseComObject(m[0]);
        }
        if(fobj==null){Console.WriteLine("no xbar");return;}
        ISpecifyPropertyPages sp=(ISpecifyPropertyPages)fobj; CAUUID c; sp.GetPages(out c);
        Guid pg=(Guid)Marshal.PtrToStructure(new IntPtr(c.pElems.ToInt64()),typeof(Guid));
        Console.WriteLine("page clsid="+pg);
        // raw CoCreateInstance
        Guid iidUnk=new Guid("00000000-0000-0000-C000-000000000046");
        Guid pgc=pg; IntPtr pUnk;
        int hr=CoCreateInstance(ref pgc, IntPtr.Zero, 1 /*INPROC*/, ref iidUnk, out pUnk);
        Console.WriteLine("CoCreateInstance(INPROC) hr=0x"+hr.ToString("x8"));
        if(hr==0){
            Console.WriteLine("  "+QI(pUnk,"IPropertyPage","B196B28F-BAB4-101A-B69C-00AA00341D07"));
            Console.WriteLine("  "+QI(pUnk,"IPropertyPage2","E9E1C51D-4C8A-46A3-8B4B-82D1C8A1D8F3"));
            Console.WriteLine("  "+QI(pUnk,"IOleObject","00000112-0000-0000-C000-000000000046"));
            Console.WriteLine("  "+QI(pUnk,"IPersist","0000010C-0000-0000-C000-000000000046"));
            Console.WriteLine("  "+QI(pUnk,"IDispatch","00020400-0000-0000-C000-000000000046"));
            Console.WriteLine("  "+QI(pUnk,"ISpecifyPropertyPages","B196B28B-BAB4-101A-B69C-00AA00341D07"));
            Marshal.Release(pUnk);
        }
        // OleCreatePropertyFrame in a background STA thread; inspect dialog from here
        IntPtr unk=Marshal.GetIUnknownForObject(fobj);
        IntPtr arr=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(arr,unk);
        string caption="PCTV-XBAR-CTRL";
        Thread t=new Thread(delegate(){ OleInitialize(IntPtr.Zero); int r=OleCreatePropertyFrame(IntPtr.Zero, 30, 30, caption, 1, arr, 0, IntPtr.Zero, 0, 0, IntPtr.Zero); Console.WriteLine("frame closed hr=0x"+r.ToString("x8")); });
        t.SetApartmentState(ApartmentState.STA); t.IsBackground=true; t.Start();
        IntPtr dlg=IntPtr.Zero;
        int me=GetCurrentProcessId();
        for(int i=0;i<10;i++){ Thread.Sleep(300);
            int found=0;
            EnumWindows(delegate(IntPtr h, IntPtr l){ int pid; GetWindowThreadProcessId(h, out pid);
                if(pid==me){ StringBuilder cls=new StringBuilder(256); GetClassName(h,cls,256); StringBuilder txt=new StringBuilder(512); GetWindowText(h,txt,512);
                    Console.WriteLine("  topwin hwnd=0x"+h.ToString("x")+" class='"+cls+"' title='"+txt+"'"); found++; if(dlg==IntPtr.Zero) dlg=h; }
                return true; }, IntPtr.Zero);
            if(found>0) break;
        }
        Console.WriteLine("dialog hwnd=0x"+dlg.ToString("x")+" exists="+IsWindow(dlg));
        if(dlg!=IntPtr.Zero){
            DumpChildren(dlg,"DLG");
            // close it
            PostMessage(dlg, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
        }
        Thread.Sleep(500);
        OleUninitialize();
    }
}
