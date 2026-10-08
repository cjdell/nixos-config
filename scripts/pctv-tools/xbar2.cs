using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class Xbar2 {
    static IMoniker FindPctv(string catGuid){
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if(de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while(em.Next(1,m,IntPtr.Zero)==0){ string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0) return m[0]; Marshal.ReleaseComObject(m[0]); }
        return null;
    }
    static IBaseFilter Bind(IMoniker m){ Guid ibf=typeof(IBaseFilter).GUID; object o=null; if(m==null)return null; m.BindToObject(null,null,ref ibf,out o); return (IBaseFilter)o; }
    static string[] Phy={"Unknown","Video_Tuner","Video_Composite","Video_SVideo","Video_RGB"};
    static void TryXbar(string tag, object o){
        IAMCrossbar cb;
        try{ cb=(IAMCrossbar)o; }catch(Exception ex){ Console.WriteLine(tag+": no IAMCrossbar ("+ex.GetType().Name+")"); return; }
        int oc,ic; cb.get_PinCounts(out oc,out ic);
        Console.WriteLine(tag+": IAMCrossbar YES outputs="+oc+" inputs="+ic);
        for(int i=0;i<ic;i++){ int rel,pt; cb.get_CrossbarPinInfo(1,i,out rel,out pt); Console.WriteLine("   IN["+i+"]="+(pt<Phy.Length?Phy[pt]:"type"+pt)); }
        for(int i=0;i<oc;i++){ int r=-1; cb.get_IsRoutedTo(i,out r); Console.WriteLine("   OUT["+i+"] <- IN["+r+"]"); }
    }
    [STAThread]
    static void Main(){
        IBaseFilter xbar=Bind(FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4"));
        IBaseFilter cap=Bind(FindPctv("65E8773D-8F56-11D0-A3B9-00A0C9223196"));
        IBaseFilter tun=Bind(FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4"));
        Console.WriteLine("--- BEFORE graph ---");
        TryXbar("xbar",xbar);
        object gObj=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("E436EBB3-524F-11CE-9F53-0020AF0BA770")));
        IGraphBuilder gb=(IGraphBuilder)gObj;
        gb.AddFilter(xbar,"xbar"); gb.AddFilter(cap,"cap"); if(tun!=null) gb.AddFilter(tun,"tuner");
        Console.WriteLine("--- AFTER add to graph ---");
        TryXbar("xbar",xbar);
        TryXbar("cap",cap);
        if(tun!=null) TryXbar("tuner",tun);
        // connect tuner->xbar->cap, then re-check
        IPin tv=PinByName(tun,"Analog Video"), xi=PinByName(xbar,"0: Video Tuner In");
        if(tv!=null&&xi!=null) Console.WriteLine("connect tuner->xbar="+("0x"+gb.Connect(tv,xi).ToString("x8")));
        IPin xo=PinByName(xbar,"0: Video Decoder Out"), ci=PinByName(cap,"Analog Video In");
        if(xo!=null&&ci!=null) Console.WriteLine("connect xbar->cap="+("0x"+gb.Connect(xo,ci).ToString("x8")));
        Console.WriteLine("--- AFTER connect ---");
        TryXbar("xbar",xbar);
        TryXbar("cap",cap);
    }
    static IPin PinByName(IBaseFilter f,string name){ if(f==null)return null; IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        while(ep.Next(1,ps,out got)==0&&got==1){ PIN_INFO pi; ps[0].QueryPinInfo(out pi); if(pi.name==name) return ps[0]; Marshal.ReleaseComObject(ps[0]); } return null; }
}
