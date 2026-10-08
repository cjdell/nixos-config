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

class PageTest {
    [DllImport("ole32.dll")] static extern int OleInitialize(IntPtr p);
    [DllImport("ole32.dll")] static extern void OleUninitialize();
    [DllImport("oleaut32.dll", CharSet=CharSet.Unicode)]
    static extern int OleCreatePropertyFrame(IntPtr hwndOwner, int x, int y, string caption, uint cObjects, IntPtr ppUnk, uint cPages, IntPtr lpPageClsID, int lcid, int dwReserved, IntPtr lpvReserved);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wp, StringBuilder lp);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("kernel32.dll")] static extern int GetCurrentProcessId();
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);

    const int CB_GETCOUNT=0x146, CB_GETCURSEL=0x147, CB_GETLBTEXT=0x148, CB_GETLBTEXTLEN=0x149, CB_SETCURSEL=0x14E, CB_SHOWDROPDOWN=0x14F;
    const int WM_COMMAND=0x111, CBN_SELCHANGE=1, CBN_SELENDOK=9, BM_CLICK=0xF5, WM_CLOSE=0x10, WM_LBUTTONDOWN=0x201, WM_LBUTTONUP=0x202;

    static string[] Items(IntPtr h){ int n=(int)SendMessage(h,CB_GETCOUNT,IntPtr.Zero,IntPtr.Zero); string[] r=new string[n];
        for(int j=0;j<n;j++){ int len=(int)SendMessage(h,CB_GETLBTEXTLEN,(IntPtr)j,IntPtr.Zero); StringBuilder sb=new StringBuilder(len+2); SendMessage(h,CB_GETLBTEXT,(IntPtr)j,sb); r[j]=sb.ToString(); } return r; }    static void Dump(IntPtr dlg,string tag){ Console.WriteLine("-- "+tag); EnumChildWindows(dlg, delegate(IntPtr h, IntPtr l){ StringBuilder cls=new StringBuilder(64); GetClassName(h,cls,64); StringBuilder tx=new StringBuilder(128); GetWindowText(h,tx,128); string cn=cls.ToString();
        string extra=""; if(cn=="ComboBox"){ extra=" cur="+SendMessage(h,CB_GETCURSEL,IntPtr.Zero,IntPtr.Zero)+" items=["+string.Join(" | ",Items(h))+"]"; }
        Console.WriteLine("   "+cn+" id="+GetDlgCtrlID(h)+" enabled="+IsWindowEnabled(h)+" parent=0x"+GetParent(h).ToString("x")+" text='"+tx+"'"+extra); return true; }, IntPtr.Zero); }

    [STAThread]
    static void Main(string[] args) {
        int item = args.Length>0?int.Parse(args[0]):2;
        // find xbar
        Guid cat=new Guid("A799A801-A46D-11D0-A18C-00A02401DCD4");
        object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; de.CreateClassEnumerator(ref cat,out em,0);
        IMoniker[] m=new IMoniker[1]; object xbar=null;
        while(em.Next(1,m,IntPtr.Zero)==0){ string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0){ Guid ibf=typeof(IBaseFilter).GUID; m[0].BindToObject(null,null,ref ibf,out xbar); break; } Marshal.ReleaseComObject(m[0]); }
        if(xbar==null){Console.WriteLine("no xbar");return;}
        int me=GetCurrentProcessId();
        IntPtr unk=Marshal.GetIUnknownForObject(xbar);
        IntPtr arr=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(arr,unk);
        string cap="PAGETEST-"+Guid.NewGuid().ToString("N");
        Thread t=new Thread(delegate(){ OleInitialize(IntPtr.Zero); OleCreatePropertyFrame(IntPtr.Zero, 10, 10, cap, 1, arr, 0, IntPtr.Zero, 0,0,IntPtr.Zero); OleUninitialize(); });
        t.SetApartmentState(ApartmentState.STA); t.IsBackground=true; t.Start();
        IntPtr dlg=IntPtr.Zero;
        for(int i=0;i<50 && !t.Join(0);i++){ Thread.Sleep(150); IntPtr f=IntPtr.Zero;
            EnumWindows(delegate(IntPtr h, IntPtr l){ int pid; GetWindowThreadProcessId(h,out pid); if(pid==me){ StringBuilder cls=new StringBuilder(64); GetClassName(h,cls,64); if(cls.ToString()=="#32770"){ StringBuilder tx=new StringBuilder(256); GetWindowText(h,tx,256); if(tx.ToString().StartsWith(cap)){ f=h; return false; } } } return true; }, IntPtr.Zero);
            if(f!=IntPtr.Zero){ dlg=f; break; } }
        if(dlg==IntPtr.Zero){ Console.WriteLine("no dialog"); return; }
        Dump(dlg,"initial");
        IntPtr combo=IntPtr.Zero;
        EnumChildWindows(dlg, delegate(IntPtr h, IntPtr l){ StringBuilder cls=new StringBuilder(64); GetClassName(h,cls,64); if(cls.ToString()!="ComboBox") return true; string[] it=Items(h); bool inV=false,outV=false; foreach(string s in it){ if(s.IndexOf("Video ",StringComparison.OrdinalIgnoreCase)>=0) inV=true; if(s.IndexOf("Decoder Out",StringComparison.OrdinalIgnoreCase)>=0) outV=true; } if(inV&&!outV) combo=h; return true; }, IntPtr.Zero);
        if(combo==IntPtr.Zero){ Console.WriteLine("no input combo"); return; }
        int cid=GetDlgCtrlID(combo); IntPtr cparent=GetParent(combo);
        Console.WriteLine("combo id="+cid+" parent=0x"+cparent.ToString("x"));
        SetForegroundWindow(dlg); ShowWindow(dlg,5);
        SendMessage(combo,CB_SETCURSEL,(IntPtr)item,IntPtr.Zero);
        Console.WriteLine("after SETCURSEL cur="+SendMessage(combo,CB_GETCURSEL,IntPtr.Zero,IntPtr.Zero));
        SendMessage(cparent,WM_COMMAND,(IntPtr)((CBN_SELCHANGE<<16)|(cid&0xffff)),combo);
        Thread.Sleep(300);
        Console.WriteLine("after CBN_SELCHANGE to parent cur="+SendMessage(combo,CB_GETCURSEL,IntPtr.Zero,IntPtr.Zero));
        Dump(dlg,"after selchange");
        // apply
        IntPtr apply=IntPtr.Zero, ok=IntPtr.Zero;
        EnumChildWindows(dlg, delegate(IntPtr h, IntPtr l){ StringBuilder cls=new StringBuilder(64); GetClassName(h,cls,64); if(cls.ToString()!="Button") return true; StringBuilder tx=new StringBuilder(64); GetWindowText(h,tx,64); if(tx.ToString().Replace("&","")=="Apply") apply=h; if(tx.ToString()=="OK") ok=h; return true; }, IntPtr.Zero);
        Console.WriteLine("apply=0x"+apply.ToString("x")+" enabled="+IsWindowEnabled(apply)+" ok=0x"+ok.ToString("x")+" enabled="+IsWindowEnabled(ok));
        if(apply!=IntPtr.Zero && IsWindowEnabled(apply)) SendMessage(apply,BM_CLICK,IntPtr.Zero,IntPtr.Zero);
        Thread.Sleep(800);
        Console.WriteLine("after apply: applyEnabled="+IsWindowEnabled(apply)+" cur="+SendMessage(combo,CB_GETCURSEL,IntPtr.Zero,IntPtr.Zero));
        Dump(dlg,"after apply");
        Console.WriteLine("dialog alive after apply="+IsWindow(dlg));
        if(ok!=IntPtr.Zero) SendMessage(ok,BM_CLICK,IntPtr.Zero,IntPtr.Zero);
        Thread.Sleep(500);
        Console.WriteLine("dialog alive after ok="+IsWindow(dlg));
        if(IsWindow(dlg)) PostMessage(dlg,WM_CLOSE,IntPtr.Zero,IntPtr.Zero);
        t.Join(3000);
    }
}
