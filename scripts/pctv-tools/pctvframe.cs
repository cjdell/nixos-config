using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

// Reuses PctvRoute.Select (compile together); main entry is PctvFrame.
class PctvFrame {
    static IMoniker FindPctv(string catGuid) {
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if (de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while (em.Next(1,m,IntPtr.Zero)==0) {
            string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if (nm.ToLower().IndexOf("pctv")>=0) return m[0];
            Marshal.ReleaseComObject(m[0]);
        }
        return null;
    }
    static IBaseFilter Bind(IMoniker m){ Guid ibf=typeof(IBaseFilter).GUID; object o=null; m.BindToObject(null,null,ref ibf,out o); return (IBaseFilter)o; }
    static IPin PinByName(IBaseFilter f,string name){ IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while(ep.Next(1,ps,out got)==0&&got==1){ PIN_INFO pi; ps[0].QueryPinInfo(out pi); if(pi.name==name) return ps[0]; Marshal.ReleaseComObject(ps[0]); } return null; }
    static IPin FirstPin(IBaseFilter f,int wantDir){ IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while(ep.Next(1,ps,out got)==0&&got==1){ int d; ps[0].QueryDirection(out d); if(d==wantDir) return ps[0]; Marshal.ReleaseComObject(ps[0]); } return null; }

    [STAThread]
    static int Main(string[] args) {
        string input = args.Length>0?args[0]:"svideo";
        string stdout = args.Length>1?args[1]:"frame.raw";
        int seconds = args.Length>2?int.Parse(args[2]):6;
        IMoniker xm=FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4");
        IMoniker cm=FindPctv("65E8773D-8F56-11D0-A3B9-00A0C9223196");
        if(xm==null||cm==null){ Console.WriteLine("PCTV filters not found (xm="+(xm!=null)+" cm="+(cm!=null)+")"); return 3; }
        IBaseFilter xbar=Bind(xm), cap=Bind(cm);
        IMoniker tm=FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4");
        IBaseFilter tun = tm!=null?Bind(tm):null;
        Console.WriteLine("bound xbar="+(xbar!=null)+" cap="+(cap!=null)+" tuner="+(tun!=null));
        object gObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("E436EBB3-524F-11CE-9F53-0020AF0BA770")));
        IGraphBuilder gb=(IGraphBuilder)gObj; IMediaControl mc=(IMediaControl)gObj;
        Console.WriteLine("AddFilter xbar hr=0x"+gb.AddFilter(xbar,"xbar").ToString("x8"));
        Console.WriteLine("AddFilter cap  hr=0x"+gb.AddFilter(cap,"cap").ToString("x8"));
        if(tun!=null) Console.WriteLine("AddFilter tuner hr=0x"+gb.AddFilter(tun,"tuner").ToString("x8"));
        if(tun!=null){
            IPin tv=PinByName(tun,"Analog Video"); IPin ti=PinByName(xbar,"0: Video Tuner In");
            if(tv!=null&&ti!=null) Console.WriteLine("Connect(tuner->xbar video) hr=0x"+gb.Connect(tv,ti).ToString("x8"));
            IPin ta=PinByName(tun,"Analog Audio"); IPin ai=PinByName(xbar,"3: Audio Tuner In");
            if(ta!=null&&ai!=null) Console.WriteLine("Connect(tuner->xbar audio) hr=0x"+gb.Connect(ta,ai).ToString("x8"));
        }
        IPin xo=PinByName(xbar,"0: Video Decoder Out");
        IPin ci=PinByName(cap,"Analog Video In");
        if(xo==null||ci==null){ Console.WriteLine("pins missing xo="+(xo!=null)+" ci="+(ci!=null)); return 4; }
        Console.WriteLine("Connect(xbar->cap) hr=0x"+gb.Connect(xo,ci).ToString("x8"));
        IPin xa=PinByName(xbar,"1: Audio Decoder Out"); IPin cai=PinByName(cap,"Analog Audio input");
        if(xa!=null&&cai!=null) Console.WriteLine("Connect(xbar audio->cap) hr=0x"+gb.Connect(xa,cai).ToString("x8"));
        // set TV format
        try { IAMAnalogVideoDecoder d=(IAMAnalogVideoDecoder)cap; int cur; d.get_TVFormat(out cur); Console.WriteLine("current TVFormat=0x"+cur.ToString("x"));
            if(args.Length>3){ int f=Convert.ToInt32(args[3],16); int h2=d.put_TVFormat(f); Console.WriteLine("put_TVFormat(0x"+f.ToString("x")+") hr=0x"+h2.ToString("x8")); } } catch(Exception ex){ Console.WriteLine("decoder: "+ex.Message); }

        object sgObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A0-3F08-11D3-9F0B-006008039E37")));
        object nrObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A4-3F08-11D3-9F0B-006008039E37")));
        IBaseFilter sg=(IBaseFilter)sgObj, nr=(IBaseFilter)nrObj;
        Console.WriteLine("AddFilter sg hr=0x"+gb.AddFilter(sg,"sg").ToString("x8"));
        Console.WriteLine("AddFilter nr hr=0x"+gb.AddFilter(nr,"nr").ToString("x8"));
        IPin co=PinByName(cap,"Capture"); IPin sgi=FirstPin(sg,0), sgo=FirstPin(sg,1), nri=FirstPin(nr,0);
        Console.WriteLine("Connect(cap->sg) hr=0x"+gb.Connect(co,sgi).ToString("x8"));
        Console.WriteLine("Connect(sg->nr)  hr=0x"+gb.Connect(sgo,nri).ToString("x8"));
        // Route AFTER the graph pins exist, else the page has nothing to program.
        int rb=PctvRoute.Select(xbar, input=="svideo"?"Video SVideo In":input=="composite"?"Video Composite In":"Video Tuner In", true);
        Console.WriteLine("route rc="+rb);
        ISampleGrabber grab=(ISampleGrabber)sgObj; grab.SetBufferSamples(true); grab.SetOneShot(false);
        Console.WriteLine("Run hr=0x"+mc.Run().ToString("x8"));
        int sz=0; bool got=false;
        for(int i=0;i<seconds*4;i++){ System.Threading.Thread.Sleep(250);
            IntPtr mtp=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(AM_MEDIA_TYPE)));
            int mh=grab.GetConnectedMediaType(mtp);
            AM_MEDIA_TYPE mt=(AM_MEDIA_TYPE)Marshal.PtrToStructure(mtp,typeof(AM_MEDIA_TYPE));
            int w=0,h=0,bits=0,comp=0;
            if(mt.pbFormat!=IntPtr.Zero){ VIDEOINFOHEADER vih=(VIDEOINFOHEADER)Marshal.PtrToStructure(mt.pbFormat,typeof(VIDEOINFOHEADER)); w=vih.bmiHeader.biWidth;h=vih.bmiHeader.biHeight;bits=vih.bmiHeader.biBitCount;comp=vih.bmiHeader.biCompression; }
            Marshal.FreeHGlobal(mtp);
            int q=0; int gh=grab.GetCurrentBuffer(ref q, IntPtr.Zero);
            if(q>0){ Console.WriteLine("frame available: "+q+" bytes, "+w+"x"+h+" bits="+bits+" comp="+comp+" (poll "+(i+1)+")");
                IntPtr buf=Marshal.AllocHGlobal(q); int g2=grab.GetCurrentBuffer(ref q, buf); byte[] data=new byte[q]; Marshal.Copy(buf,data,0,q); File.WriteAllBytes(stdout,data);
                Console.WriteLine("wrote "+q+" bytes -> "+stdout+" hr=0x"+g2.ToString("x8")); Marshal.FreeHGlobal(buf); got=true; break; }
            if(i==0) Console.WriteLine("waiting for frames ("+w+"x"+h+" bits="+bits+")...");
        }
        if(!got) Console.WriteLine("!! no frame after "+seconds+"s");
        mc.Stop();
        return got?0:1;
    }
}
