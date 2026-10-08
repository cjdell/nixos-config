using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class VtProbe {
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int Vf(IntPtr pThis, IntPtr a, IntPtr b, IntPtr c);
    static IMoniker FindPctv(string catGuid){
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if(de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while(em.Next(1,m,IntPtr.Zero)==0){ string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0) return m[0]; Marshal.ReleaseComObject(m[0]); }
        return null;
    }
    static IBaseFilter Bind(IMoniker m){ Guid ibf=typeof(IBaseFilter).GUID; object o=null; m.BindToObject(null,null,ref ibf,out o); return (IBaseFilter)o; }
    static string Names(int i){
        string[] IAMTuner={"put_Channel","get_Channel","ChannelMinMax","put_CountryCode","get_CountryCode","put_TuningSpace","get_TuningSpace","Logon","Logout","SignalPresent","put_Mode","get_Mode","GetNumInputConnections","put_InputType","get_InputType","put_ConnectInput","get_ConnectInput","get_VideoFrequency","get_AudioFrequency"};
        string[] IAMTVTuner={"get_AvailableTVFormats","get_TVFormat","AutoTune","StoreAutoTune"};
        int k=i-3;
        if(k<0) return "IUnknown";
        if(k<IAMTuner.Length) return "IAMTuner."+IAMTuner[k];
        if(k<IAMTuner.Length+IAMTVTuner.Length) return "IAMTVTuner."+IAMTVTuner[k-IAMTuner.Length];
        return "?";
    }
    [STAThread]
    static void Main(){
        IBaseFilter tun=Bind(FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4"));
        Guid iid=new Guid("211A8766-03AC-11D1-8D13-00AA00BD8339");
        IntPtr unk=Marshal.GetIUnknownForObject(tun); IntPtr iface; int hr=Marshal.QueryInterface(unk,ref iid,out iface);
        Console.WriteLine("QI hr=0x"+hr.ToString("x8"));
        if(hr!=0) return;
        IntPtr vtbl=Marshal.ReadIntPtr(iface);
        Console.WriteLine("iface=0x"+iface.ToString("x")+" vtbl=0x"+vtbl.ToString("x"));
        Vf vf=(Vf)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl,0), typeof(Vf));
        for(int slot=3;slot<27;slot++){
            IntPtr fn=Marshal.ReadIntPtr(vtbl,slot*IntPtr.Size);
            Vf f=(Vf)Marshal.GetDelegateForFunctionPointer(fn,typeof(Vf));
            IntPtr a=Marshal.AllocHGlobal(16), b=Marshal.AllocHGlobal(16), c=Marshal.AllocHGlobal(16);
            for(int i=0;i<16;i++){ Marshal.WriteByte(a,i,0); Marshal.WriteByte(b,i,0); Marshal.WriteByte(c,i,0); }
            int r=0; string ex="";
            try{ r=f(iface,a,b,c); }catch(Exception e){ ex=e.GetType().Name; }
            int va=Marshal.ReadInt32(a), vb=Marshal.ReadInt32(b);
            Console.WriteLine("slot "+slot.ToString().PadLeft(2)+" "+Names(slot).PadRight(28)+" hr=0x"+r.ToString("x8")+"  a0="+va+" b0="+vb+" "+ex);
            Marshal.FreeHGlobal(a); Marshal.FreeHGlobal(b); Marshal.FreeHGlobal(c);
        }
        Marshal.Release(iface); Marshal.Release(unk);
    }
}
