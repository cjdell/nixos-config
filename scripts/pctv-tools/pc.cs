using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("211A8766-03AC-11D1-8D13-00AA00BD8339"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAMTV {  // corrected IAMTuner + IAMTVTuner layout (per vtable scan)
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
    [PreserveSig] int get_AvailableTVFormats(out int f);
    [PreserveSig] int get_TVFormat(out int f);
    [PreserveSig] int AutoTune(int ch, out int found);
    [PreserveSig] int StoreAutoTune();
    [PreserveSig] int put_ConnectInput(int idx);
    [PreserveSig] int get_ConnectInput(out int idx);
    [PreserveSig] int get_VideoFrequency(out int f);
    [PreserveSig] int get_AudioFrequency(out int f);
}

class Pc {
    static IMoniker FindPctv(string catGuid){
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if(de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while(em.Next(1,m,IntPtr.Zero)==0){ string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0) return m[0]; Marshal.ReleaseComObject(m[0]); }
        return null;
    }
    static IBaseFilter Bind(IMoniker m){ Guid ibf=typeof(IBaseFilter).GUID; object o=null; m.BindToObject(null,null,ref ibf,out o); return (IBaseFilter)o; }
    [STAThread]
    static void Main(string[] args){
        IAMTV tv=(IAMTV)Bind(FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4"));
        int n,f,cur,tf;
        Console.WriteLine("GetNumInputConnections="+tv.GetNumInputConnections(out n)+" n="+n);
        Console.WriteLine("get_AvailableTVFormats="+tv.get_AvailableTVFormats(out f)+" f=0x"+f.ToString("x"));
        Console.WriteLine("get_TVFormat="+tv.get_TVFormat(out tf)+" tf=0x"+tf.ToString("x"));
        Console.WriteLine("get_ConnectInput="+tv.get_ConnectInput(out cur)+" cur="+cur);
        if(args.Length>0){
            int idx=int.Parse(args[0]);
            Console.WriteLine("put_ConnectInput("+idx+")="+tv.put_ConnectInput(idx));
            Console.WriteLine("get_ConnectInput now="+tv.get_ConnectInput(out cur)+" cur="+cur);
            Console.WriteLine("SignalPresent="+tv.SignalPresent(out f)+" s="+f);
        }
    }
}
