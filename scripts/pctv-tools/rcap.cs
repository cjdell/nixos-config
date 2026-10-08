using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class Rcap {
    static IMoniker FindPctv(string catGuid){
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if(de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while(em.Next(1,m,IntPtr.Zero)==0){ string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0) return m[0]; Marshal.ReleaseComObject(m[0]); }
        return null;
    }
    static IBaseFilter Bind(IMoniker m){ Guid ibf=typeof(IBaseFilter).GUID; object o=null; if(m==null)return null; m.BindToObject(null,null,ref ibf,out o); return (IBaseFilter)o; }
    static IPin PinByName(IBaseFilter f,string name){ IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while(ep.Next(1,ps,out got)==0&&got==1){ PIN_INFO pi; ps[0].QueryPinInfo(out pi); if(pi.name==name) return ps[0]; Marshal.ReleaseComObject(ps[0]); } return null; }
    static string H(int hr){ return "0x"+hr.ToString("x8"); }
    static Guid CAPTURE=new Guid("FB6C4281-0353-11D1-905F-0000C0CC16BA");
    static Guid PREVIEW=new Guid("FB6C4282-0353-11D1-905F-0000C0CC16BA");
    static Guid VID=new Guid("73646976-0000-0010-8000-00AA00389B71");

    [STAThread]
    static int Main(string[] args){
        string input=args.Length>0?args[0]:"svideo";
        int secs=args.Length>1?int.Parse(args[1]):5;
        IBaseFilter tun=Bind(FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4"));
        IBaseFilter xbar=Bind(FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4"));
        IBaseFilter cap=Bind(FindPctv("65E8773D-8F56-11D0-A3B9-00A0C9223196"));
        object gObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("E436EBB3-524F-11CE-9F53-0020AF0BA770")));
        IGraphBuilder gb=(IGraphBuilder)gObj; IMediaControl mc=(IMediaControl)gObj;
        object cObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BF87B6E1-8C27-11D0-B3F0-00AA003761C5")));
        ICaptureGraphBuilder2 cgb=(ICaptureGraphBuilder2)cObj;
        cgb.SetFiltergraph(gb);
        gb.AddFilter(tun,"tuner"); gb.AddFilter(xbar,"xbar"); gb.AddFilter(cap,"cap");
        Console.WriteLine("tun->xbar="+H(gb.Connect(PinByName(tun,"Analog Video"),PinByName(xbar,"0: Video Tuner In"))));
        Console.WriteLine("xbar->cap="+H(gb.Connect(PinByName(xbar,"0: Video Decoder Out"),PinByName(cap,"Analog Video In"))));
        // route BEFORE RenderStream (which will insert a smart tee / compressors)
        Console.WriteLine("route rc="+PctvRoute.Select(xbar, input=="svideo"?"Video SVideo In":input=="composite"?"Video Composite In":"Video Tuner In", true));
        object nrObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A4-3F08-11D3-9F0B-006008039E37")));
        IBaseFilter nr=(IBaseFilter)nrObj;
        int hr=cgb.RenderStream(ref PREVIEW, ref VID, Marshal.GetIUnknownForObject(cap), null, nr);
        Console.WriteLine("RenderStream(PREVIEW) hr="+H(hr));
        hr=cgb.RenderStream(ref CAPTURE, ref VID, Marshal.GetIUnknownForObject(cap), null, nr);
        Console.WriteLine("RenderStream(CAPTURE) hr="+H(hr));
        // if RenderStream added filters, re-route on the same xbar (still the same instance)
        Console.WriteLine("re-route rc="+PctvRoute.Select(xbar, input=="svideo"?"Video SVideo In":input=="composite"?"Video Composite In":"Video Tuner In", false));
        IAMAnalogVideoDecoder dec=(IAMAnalogVideoDecoder)cap; dec.put_TVFormat(0x10);
        Console.WriteLine("Run="+H(mc.Run()));
        System.Threading.Thread.Sleep(secs*1000);
        int st; mc.GetState(0,out st); Console.WriteLine("state="+st);
        // list filters present
        IntPtr ef; gb.EnumFilters(out ef);
        Marshal.ReleaseComObject(gb);
        return 0;
    }
}
