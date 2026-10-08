using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class CgbTest {
    static IMoniker FindPctv(string catGuid){
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if(de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while(em.Next(1,m,IntPtr.Zero)==0){ string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0) return m[0]; Marshal.ReleaseComObject(m[0]); }
        return null;
    }
    static IBaseFilter Bind(IMoniker m){ Guid ibf=typeof(IBaseFilter).GUID; object o=null; m.BindToObject(null,null,ref ibf,out o); return (IBaseFilter)o; }
    static IPin PinByName(IBaseFilter f,string name){ IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while(ep.Next(1,ps,out got)==0&&got==1){ PIN_INFO pi; ps[0].QueryPinInfo(out pi); if(pi.name==name) return ps[0]; Marshal.ReleaseComObject(ps[0]); } return null; }
    static string H(int hr){ return "0x"+hr.ToString("x8"); }

    [STAThread]
    static int Main(string[] args){
        string input=args.Length>0?args[0]:"svideo";
        string outFile=args.Length>1?args[1]:"C:\\Users\\Chris\\cap.avi";
        int secs=args.Length>2?int.Parse(args[2]):8;
        bool caponly = args.Length>3 && args[3]=="caponly";
        bool withTuner=!(args.Length>3 && (args[3]=="notuner"||caponly));
        bool withXbar=!(args.Length>3 && (args[3]=="noxbar"||caponly));
        Guid MEDIATYPE_Video=new Guid("73646976-0000-0010-8000-00AA00389B71");
        Guid PIN_CATEGORY_CAPTURE=new Guid("FB6C4281-0353-11D1-905F-0000C0CC16BA");
        Guid MEDIASUBTYPE_Avi=new Guid("e436eb8e-524f-11ce-9f53-0020af0ba770");

        object gObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("E436EBB3-524F-11CE-9F53-0020AF0BA770")));
        IGraphBuilder gb=(IGraphBuilder)gObj; IMediaControl mc=(IMediaControl)gObj;
        object cObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BF87B6E1-8C27-11D0-B3F0-00AA003761C5")));
        ICaptureGraphBuilder2 cgb=(ICaptureGraphBuilder2)cObj;
        Console.WriteLine("SetFiltergraph hr="+H(cgb.SetFiltergraph(gb)));
        IBaseFilter cap=Bind(FindPctv("65E8773D-8F56-11D0-A3B9-00A0C9223196"));
        IBaseFilter xbar=withXbar?Bind(FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4")):null;
        IBaseFilter tun=withTuner?Bind(FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4")):null;
        Console.WriteLine("Add cap="+H(gb.AddFilter(cap,"cap")));
        if(xbar!=null) Console.WriteLine("Add xbar="+H(gb.AddFilter(xbar,"xbar")));
        if(tun!=null) Console.WriteLine("Add tuner="+H(gb.AddFilter(tun,"tuner")));
        if(xbar!=null && tun!=null){
            Console.WriteLine("tuner->xbar video="+H(gb.Connect(PinByName(tun,"Analog Video"),PinByName(xbar,"0: Video Tuner In"))));
            Console.WriteLine("tuner->xbar audio="+H(gb.Connect(PinByName(tun,"Analog Audio"),PinByName(xbar,"3: Audio Tuner In"))));
        }
        if(xbar!=null){
            Console.WriteLine("xbar->cap video="+H(gb.Connect(PinByName(xbar,"0: Video Decoder Out"),PinByName(cap,"Analog Video In"))));
            Console.WriteLine("xbar->cap audio="+H(gb.Connect(PinByName(xbar,"1: Audio Decoder Out"),PinByName(cap,"Analog Audio input"))));
        }
        IBaseFilter mux; IFileSinkFilter sink;
        Console.WriteLine("SetOutputFileName("+outFile+")="+H(cgb.SetOutputFileName(ref MEDIASUBTYPE_Avi,outFile,out mux,out sink)));
        Console.WriteLine("RenderStream(CAPTURE)= "+H(cgb.RenderStream(ref PIN_CATEGORY_CAPTURE, ref MEDIATYPE_Video, Marshal.GetIUnknownForObject(cap), null, mux)));
        if(xbar!=null){
            int rb=PctvRoute.Select(xbar, input=="svideo"?"Video SVideo In":input=="composite"?"Video Composite In":"Video Tuner In", true);
            Console.WriteLine("route rc="+rb);
        }
        Console.WriteLine("Run hr="+H(mc.Run()));
        System.Threading.Thread.Sleep(secs*1000);
        try{ int st; mc.GetState(0,out st); Console.WriteLine("state="+st);}catch{}
        FileInfo fi=new FileInfo(outFile);
        Console.WriteLine("file size="+(fi.Exists?fi.Length:0));
        mc.Stop();
        return 0;
    }
}
