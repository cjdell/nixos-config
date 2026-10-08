using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class PctvRoute {
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
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("kernel32.dll")] static extern int GetCurrentProcessId();
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr wp, IntPtr lp);

    const int CB_GETCOUNT=0x146, CB_GETCURSEL=0x147, CB_GETLBTEXT=0x148, CB_GETLBTEXTLEN=0x149, CB_SETCURSEL=0x14E;
    const int WM_COMMAND=0x111, CBN_SELCHANGE=1, BM_CLICK=0xF5, WM_CLOSE=0x10;

    // physical input pin names, from the driver's crossbar
    public static readonly string[] Names = { "0: Video Tuner In", "1: Video SVideo In", "2: Video Composite In" };

    static string[] ComboItems(IntPtr h) {
        int n=(int)SendMessage(h,CB_GETCOUNT,IntPtr.Zero,IntPtr.Zero);
        string[] r=new string[n];
        for(int j=0;j<n;j++){
            int len=(int)SendMessage(h,CB_GETLBTEXTLEN,(IntPtr)j,IntPtr.Zero);
            StringBuilder sb=new StringBuilder(len+2); SendMessage(h,CB_GETLBTEXT,(IntPtr)j,sb);
            r[j]=sb.ToString();
        }
        return r;
    }

    /// <summary>Open the driver crossbar property page off-screen, pick the input, apply, close.</summary>
    public static int Select(object xbarFilter, string inputName, bool verbose) {
        int me=GetCurrentProcessId();
        Console.WriteLine("  [route] opening crossbar property page...");
        IntPtr unk=Marshal.GetIUnknownForObject(xbarFilter);
        IntPtr arr=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(arr,unk);
        string caption="PCTVROUTE-"+Guid.NewGuid().ToString("N");
        int frameHr=int.MinValue;
        Thread t=new Thread(delegate(){
            OleInitialize(IntPtr.Zero);
            frameHr=OleCreatePropertyFrame(IntPtr.Zero, 0, 0, caption, 1, arr, 0, IntPtr.Zero, 0, 0, IntPtr.Zero);
            OleUninitialize();
        });
        t.SetApartmentState(ApartmentState.STA); t.IsBackground=true; t.Start();

        IntPtr dlg=IntPtr.Zero;
        for(int i=0;i<40 && !t.Join(0);i++){
            Thread.Sleep(150);
            IntPtr found=IntPtr.Zero;
            EnumWindows(delegate(IntPtr h, IntPtr l){ int pid; GetWindowThreadProcessId(h, out pid);
                if(pid==me){ StringBuilder cls=new StringBuilder(64); GetClassName(h,cls,64);
                    if(cls.ToString()=="#32770"){ StringBuilder tx=new StringBuilder(256); GetWindowText(h,tx,256);
                        if(tx.ToString().StartsWith(caption)){ found=h; return false; } } }
                return true; }, IntPtr.Zero);
            if(found!=IntPtr.Zero){ dlg=found; break; }
        }
        if(dlg==IntPtr.Zero){ Console.WriteLine("  [route] ERROR: property page did not appear"); return -1; }
        if(verbose) Console.WriteLine("  [route] page hwnd=0x"+dlg.ToString("x"));

        IntPtr inputCombo=IntPtr.Zero; int target=-1; int cur=-1;
        EnumChildWindows(dlg, delegate(IntPtr h, IntPtr l){
            StringBuilder cls=new StringBuilder(64); GetClassName(h,cls,64);
            if(cls.ToString()!="ComboBox") return true;
            string[] items=ComboItems(h);
            bool isInput=false, isOutput=false;
            foreach(string s in items){ if(s.IndexOf("Video ",StringComparison.OrdinalIgnoreCase)>=0){ isInput=true; } if(s.IndexOf("Decoder Out",StringComparison.OrdinalIgnoreCase)>=0){ isOutput=true; } }
            if(isInput && !isOutput){
                if(inputName!=null) for(int j=0;j<items.Length;j++) if(items[j].IndexOf(inputName,StringComparison.OrdinalIgnoreCase)>=0){ inputCombo=h; target=j; }
                if(verbose) Console.WriteLine("  [route] Input combo items: "+string.Join(" | ",items)+" cur="+SendMessage(h,CB_GETCURSEL,IntPtr.Zero,IntPtr.Zero));
                cur=(int)SendMessage(h,CB_GETCURSEL,IntPtr.Zero,IntPtr.Zero);
            }
            return true; }, IntPtr.Zero);

        if(inputName==null){ PostMessage(dlg,WM_CLOSE,IntPtr.Zero,IntPtr.Zero); t.Join(3000);
            Console.WriteLine("  [route] current input index = "+cur);
            return cur<0?-3:cur; }
        if(inputCombo==IntPtr.Zero || target<0){ Console.WriteLine("  [route] ERROR: input '"+inputName+"' not found"); PostMessage(dlg,WM_CLOSE,IntPtr.Zero,IntPtr.Zero); t.Join(4000); return -2; }

        int cid=GetDlgCtrlID(inputCombo);
        IntPtr cparent=GetParent(inputCombo);
        SendMessage(inputCombo,CB_SETCURSEL,(IntPtr)target,IntPtr.Zero);
        // NB: the notification must go to the combo's immediate parent dialog, not the frame;
        // only then does the page mark itself dirty and enable Apply.
        SendMessage(cparent,WM_COMMAND,(IntPtr)((CBN_SELCHANGE<<16)|(cid&0xffff)),inputCombo);
        Thread.Sleep(250);
        // click Apply then OK
        IntPtr apply=IntPtr.Zero, ok=IntPtr.Zero;
        EnumChildWindows(dlg, delegate(IntPtr h, IntPtr l){
            StringBuilder cls=new StringBuilder(64); GetClassName(h,cls,64);
            if(cls.ToString()!="Button") return true;
            StringBuilder tx=new StringBuilder(64); GetWindowText(h,tx,64);
            string s=tx.ToString().Replace("&","");
            if(s=="Apply") apply=h; if(s=="OK") ok=h;
            return true; }, IntPtr.Zero);
        if(apply!=IntPtr.Zero){ SendMessage(apply,BM_CLICK,IntPtr.Zero,IntPtr.Zero); Thread.Sleep(300); }
        if(ok!=IntPtr.Zero) SendMessage(ok,BM_CLICK,IntPtr.Zero,IntPtr.Zero);
        else PostMessage(dlg,WM_CLOSE,IntPtr.Zero,IntPtr.Zero);
        if(!t.Join(5000)){ Console.WriteLine("  [route] WARN: property page thread still alive"); PostMessage(dlg,WM_CLOSE,IntPtr.Zero,IntPtr.Zero); t.Join(2000); }
        if(verbose) Console.WriteLine("  [route] set input -> '"+inputName+"' (item "+target+"), frame hr=0x"+frameHr.ToString("x8"));
        return target;
    }

    static object FindXbar() {
        Guid cat=new Guid("A799A801-A46D-11D0-A18C-00A02401DCD4");
        object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if(de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while(em.Next(1,m,IntPtr.Zero)==0){
            string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0){ Guid ibf=typeof(IBaseFilter).GUID; object f; m[0].BindToObject(null,null,ref ibf,out f); return f; }
            Marshal.ReleaseComObject(m[0]);
        }
        return null;
    }

    [STAThread]
    static int Main(string[] args) {
        if(args.Length<1){ Console.WriteLine("usage: pctvroute <svideo|composite|tuner|1|2|0>"); return 9; }
        string a=args[0].ToLower();
        object xbar=FindXbar();
        if(xbar==null){ Console.WriteLine("PCTV crossbar not found"); return 3; }
        if(a=="read"){ int rr=Select(xbar,null,true); Console.WriteLine((rr>=0?"CURRENT "+Names[rr]:"READ FAILED")); return rr>=0?0:1; }
        if(a=="test"){ Console.WriteLine("before:"); int b=Select(xbar,null,false); Console.WriteLine("  ="+b);
            Console.WriteLine("set composite..."); int s=Select(xbar,"Video Composite In",true); Console.WriteLine("  set rc="+s);
            Console.WriteLine("after (same object):"); int c=Select(xbar,null,false); Console.WriteLine("  ="+c); return c==2?0:1; }
        string name = a=="svideo"?"Video SVideo In" : a=="composite"?"Video Composite In" : a=="tuner"?"Video Tuner In" : Names[int.Parse(a)];
        int r=Select(xbar,name,true);
        Console.WriteLine(r>=0?"ROUTE OK":"ROUTE FAILED");
        return r>=0?0:1;
    }
}
