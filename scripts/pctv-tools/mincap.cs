using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class MinCap {
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
    static IPin FirstPin(IBaseFilter f,int wantDir){ IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while(ep.Next(1,ps,out got)==0&&got==1){ int d; ps[0].QueryDirection(out d); if(d==wantDir) return ps[0]; Marshal.ReleaseComObject(ps[0]); } return null; }
    static string H(int hr){ return "0x"+hr.ToString("x8"); }

    [STAThread]
    static int Main(string[] args){
        string input=args.Length>0?args[0]:"svideo";
        string outFile=args.Length>1?args[1]:"C:\\Users\\Chris\\m.raw";
        int secs=args.Length>2?int.Parse(args[2]):8;
        string std=args.Length>3?args[3]:"pal";
        IBaseFilter xbar=Bind(FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4"));
        IBaseFilter cap=Bind(FindPctv("65E8773D-8F56-11D0-A3B9-00A0C9223196"));
        IBaseFilter tun=Bind(FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4"));
        bool wantTun=!(args.Length>4 && args[4]=="notun");
        object gObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("E436EBB3-524F-11CE-9F53-0020AF0BA770")));
        IGraphBuilder gb=(IGraphBuilder)gObj; IMediaControl mc=(IMediaControl)gObj;
        Console.WriteLine("add xbar="+H(gb.AddFilter(xbar,"xbar"))+" cap="+H(gb.AddFilter(cap,"cap")));
        if(wantTun){ Console.WriteLine("add tuner="+H(gb.AddFilter(tun,"tuner")));
            Console.WriteLine("tun->xbar video="+H(gb.Connect(PinByName(tun,"Analog Video"),PinByName(xbar,"0: Video Tuner In"))));
            Console.WriteLine("tun->xbar audio="+H(gb.Connect(PinByName(tun,"Analog Audio"),PinByName(xbar,"3: Audio Tuner In")))); }
        Console.WriteLine("xbar->cap video="+H(gb.Connect(PinByName(xbar,"0: Video Decoder Out"),PinByName(cap,"Analog Video In"))));
        Console.WriteLine("xbar->cap audio="+H(gb.Connect(PinByName(xbar,"1: Audio Decoder Out"),PinByName(cap,"Analog Audio input"))));
        object sgObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A0-3F08-11D3-9F0B-006008039E37")));
        object nrObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A4-3F08-11D3-9F0B-006008039E37")));
        IBaseFilter sg=(IBaseFilter)sgObj, nr=(IBaseFilter)nrObj;
        gb.AddFilter(sg,"sg"); gb.AddFilter(nr,"nr");
        Console.WriteLine("cap->sg="+H(gb.Connect(PinByName(cap,"Capture"),FirstPin(sg,0)))+" sg->nr="+H(gb.Connect(FirstPin(sg,1),FirstPin(nr,0))));
        IPin ca=PinByName(cap,"Audio");
        if(ca!=null){ object nr2Obj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A4-3F08-11D3-9F0B-006008039E37"))); IBaseFilter nr2=(IBaseFilter)nr2Obj; gb.AddFilter(nr2,"nr2");
            Console.WriteLine("cap audio->nr2="+H(gb.Connect(ca,FirstPin(nr2,0)))); }
        try{ IAMAnalogVideoDecoder d=(IAMAnalogVideoDecoder)cap; int avail; d.get_AvailableTVFormats(out avail);
            int f = std=="ntsc"?0x1 : std=="secam"?0x1000 : 0x10;
            Console.WriteLine("put_TVFormat("+std+"/0x"+f.ToString("x")+")="+H(d.put_TVFormat(f)));
        }catch(Exception ex){Console.WriteLine("decoder: "+ex.Message);}
        int rb=PctvRoute.Select(xbar, input=="svideo"?"Video SVideo In":input=="composite"?"Video Composite In":"Video Tuner In", true);
        Console.WriteLine("route rc="+rb);
        int cr=cap.Run(0); Console.WriteLine("cap.Run="+H(cr));
        int pr=mc.Pause(); Console.WriteLine("mc.Pause="+H(pr));
        int runHr=mc.Run(); Console.WriteLine("Run="+H(runHr));
        for(int attempt=1; attempt<=5 && runHr!=0; attempt++){
            System.Threading.Thread.Sleep(3000);
            mc.Stop();
            cap.Run(0);
            runHr=mc.Run();
            Console.WriteLine("retry "+attempt+": Run="+H(runHr));
        }
        ISampleGrabber grab=(ISampleGrabber)sgObj; grab.SetBufferSamples(true); grab.SetOneShot(false);
        int sz=0; bool got=false;
        for(int i=0;i<secs*4;i++){ System.Threading.Thread.Sleep(250);
            IntPtr mtp=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(AM_MEDIA_TYPE)));
            grab.GetConnectedMediaType(mtp);
            AM_MEDIA_TYPE mt=(AM_MEDIA_TYPE)Marshal.PtrToStructure(mtp,typeof(AM_MEDIA_TYPE));
            int w=0,h=0,bits=0;
            if(mt.pbFormat!=IntPtr.Zero){ VIDEOINFOHEADER vih=(VIDEOINFOHEADER)Marshal.PtrToStructure(mt.pbFormat,typeof(VIDEOINFOHEADER)); w=vih.bmiHeader.biWidth;h=vih.bmiHeader.biHeight;bits=vih.bmiHeader.biBitCount; }
            Marshal.FreeHGlobal(mtp);
            int q=0; grab.GetCurrentBuffer(ref q, IntPtr.Zero);
            if(q>0){ Console.WriteLine("FRAME "+q+" bytes "+w+"x"+h+" bits="+bits+" at poll "+(i+1));
                IntPtr buf=Marshal.AllocHGlobal(q); grab.GetCurrentBuffer(ref q,buf); byte[] data=new byte[q]; Marshal.Copy(buf,data,0,q);
                File.WriteAllBytes(outFile,data); Marshal.FreeHGlobal(buf); Console.WriteLine("wrote "+outFile); got=true; break; }
        }
        if(!got) Console.WriteLine("!! no frame");
        mc.Stop(); return got?0:1;
    }
}
