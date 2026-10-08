using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("211A8766-03AC-11D1-8D13-00AA00BD8339"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAMTVTuner {
    // IAMTuner
    [PreserveSig] int put_Channel(int ch, int vsub, int asub);
    [PreserveSig] int get_Channel(out int ch, out int vsub, out int asub);
    [PreserveSig] int ChannelMinMax(out int lo, out int hi);
    [PreserveSig] int put_CountryCode(int c);
    [PreserveSig] int get_CountryCode(out int c);
    [PreserveSig] int put_TuningSpace(int t);
    [PreserveSig] int get_TuningSpace(out int t);
    [PreserveSig] int Logon(IntPtr h);
    [PreserveSig] int Logout();
    [PreserveSig] int SignalPresent(out int s);
    [PreserveSig] int put_Mode(int m);
    [PreserveSig] int get_Mode(out int m);
    [PreserveSig] int GetNumInputConnections(out int n);
    [PreserveSig] int put_InputType(int idx, int type);
    [PreserveSig] int get_InputType(int idx, out int type);
    [PreserveSig] int put_ConnectInput(int idx);
    [PreserveSig] int get_ConnectInput(out int idx);
    [PreserveSig] int get_VideoFrequency(out int f);
    [PreserveSig] int get_AudioFrequency(out int f);
    // IAMTVTuner
    [PreserveSig] int get_AvailableTVFormats(out int f);
    [PreserveSig] int get_TVFormat(out int f);
    [PreserveSig] int AutoTune(int ch, out int found);
    [PreserveSig] int StoreAutoTune();
}

class TunCap {
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
    static IPin FirstPin(IBaseFilter f,int wantDir){ IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while(ep.Next(1,ps,out got)==0&&got==1){ int d; ps[0].QueryDirection(out d); if(d==wantDir) return ps[0]; Marshal.ReleaseComObject(ps[0]); } return null; }
    static string H(int hr){ return "0x"+hr.ToString("x8"); }

    [STAThread]
    static int Main(string[] args){
        string outFile=args.Length>0?args[0]:"C:\\Users\\Chris\\t.raw";
        int secs=args.Length>1?int.Parse(args[1]):4;
        IBaseFilter tun=Bind(FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4"));
        IBaseFilter xbar=Bind(FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4"));
        IBaseFilter cap=Bind(FindPctv("65E8773D-8F56-11D0-A3B9-00A0C9223196"));
        object gObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("E436EBB3-524F-11CE-9F53-0020AF0BA770")));
        IGraphBuilder gb=(IGraphBuilder)gObj; IMediaControl mc=(IMediaControl)gObj;
        gb.AddFilter(tun,"tuner"); gb.AddFilter(xbar,"xbar"); gb.AddFilter(cap,"cap");
        Console.WriteLine("tun->xbar video="+H(gb.Connect(PinByName(tun,"Analog Video"),PinByName(xbar,"0: Video Tuner In"))));
        Console.WriteLine("xbar->cap video="+H(gb.Connect(PinByName(xbar,"0: Video Decoder Out"),PinByName(cap,"Analog Video In"))));
        object sgObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A0-3F08-11D3-9F0B-006008039E37")));
        object nrObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C1F400A4-3F08-11D3-9F0B-006008039E37")));
        IBaseFilter sg=(IBaseFilter)sgObj, nr=(IBaseFilter)nrObj; gb.AddFilter(sg,"sg"); gb.AddFilter(nr,"nr");
        Console.WriteLine("cap->sg="+H(gb.Connect(PinByName(cap,"Capture"),FirstPin(sg,0)))+" sg->nr="+H(gb.Connect(FirstPin(sg,1),FirstPin(nr,0))));
        IAMTVTuner tv=null; try{tv=(IAMTVTuner)tun;}catch(Exception ex){Console.WriteLine("no IAMTVTuner: "+ex.Message);return 2;}
        int avail; Console.WriteLine("get_AvailableTVFormats hr="+H(tv.get_AvailableTVFormats(out avail))+" =0x"+avail.ToString("x"));
        int n; Console.WriteLine("GetNumInputConnections hr="+H(tv.GetNumInputConnections(out n))+" n="+n);
        int cur; Console.WriteLine("get_ConnectInput hr="+H(tv.get_ConnectInput(out cur))+" cur="+cur);
        IAMAnalogVideoDecoder dec=(IAMAnalogVideoDecoder)cap;
        ISampleGrabber grab=(ISampleGrabber)sgObj; grab.SetBufferSamples(true); grab.SetOneShot(false);
        for(int i=0;i<n;i++){
            int it; tv.get_InputType(i,out it);
            Console.WriteLine("--- try input index "+i+" (type="+it+") ---");
            tv.put_ConnectInput(i);
            tv.put_InputType(i,it);
            tv.put_Channel(1,0,0);
            dec.put_TVFormat(0x10); // PAL_B
            Console.WriteLine("  Run="+H(mc.Run()));
            bool got=false;
            for(int k=0;k<secs*4;k++){ System.Threading.Thread.Sleep(250);
                IntPtr mtp=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(AM_MEDIA_TYPE))); grab.GetConnectedMediaType(mtp);
                AM_MEDIA_TYPE mt=(AM_MEDIA_TYPE)Marshal.PtrToStructure(mtp,typeof(AM_MEDIA_TYPE));
                int w=0,h=0; if(mt.pbFormat!=IntPtr.Zero){ VIDEOINFOHEADER v=(VIDEOINFOHEADER)Marshal.PtrToStructure(mt.pbFormat,typeof(VIDEOINFOHEADER)); w=v.bmiHeader.biWidth;h=v.bmiHeader.biHeight; }
                Marshal.FreeHGlobal(mtp);
                int q=0; grab.GetCurrentBuffer(ref q,IntPtr.Zero);
                if(q>0){ Console.WriteLine("  FRAME "+q+" bytes "+w+"x"+h); IntPtr b=Marshal.AllocHGlobal(q); grab.GetCurrentBuffer(ref q,b);
                    byte[] d=new byte[q]; Marshal.Copy(b,d,0,q); File.WriteAllBytes(outFile,d); Marshal.FreeHGlobal(b); Console.WriteLine("  wrote "+outFile); got=true; break; }
            }
            if(got){ Console.WriteLine("SUCCESS at input "+i); mc.Stop(); return 0; }
            Console.WriteLine("  no frame at input "+i);
            mc.Stop();
        }
        return 1;
    }
}
