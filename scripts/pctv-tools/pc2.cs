using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class Pc2 {
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
    static Vf Sl(IntPtr vtbl,int i){ return (Vf)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl,i*IntPtr.Size),typeof(Vf)); }
    static int GetSlot(IntPtr iface, IntPtr vtbl, int slot){ IntPtr b=Marshal.AllocHGlobal(8); Marshal.WriteInt32(b,0,-12345);
        int hr=Sl(vtbl,slot)(iface,b,IntPtr.Zero,IntPtr.Zero); int v=Marshal.ReadInt32(b,0); Marshal.FreeHGlobal(b);
        Console.Write("  get slot"+slot+" hr=0x"+hr.ToString("x8")+" val="+v); return v; }
    [STAThread]
    static void Main(string[] args){
        IBaseFilter tun=Bind(FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4"));
        Guid iid=new Guid("211A8766-03AC-11D1-8D13-00AA00BD8339");
        IntPtr unk=Marshal.GetIUnknownForObject(tun); IntPtr iface; int hr=Marshal.QueryInterface(unk,ref iid,out iface);
        if(hr!=0){ Console.WriteLine("QI fail"); return; }
        IntPtr vtbl=Marshal.ReadIntPtr(iface);
        if(args.Length==0){ Console.WriteLine("usage: pc2 <slot> <idx>"); return; }
        int slot=int.Parse(args[0]); int idx=args.Length>1?int.Parse(args[1]):0;
        Console.Write("before slot22: "); GetSlot(iface,vtbl,22); Console.WriteLine();
        int r=Sl(vtbl,slot)(iface,(IntPtr)idx,IntPtr.Zero,IntPtr.Zero);
        Console.WriteLine("slot"+slot+"("+idx+") hr=0x"+r.ToString("x8"));
        Console.Write("after  slot22: "); GetSlot(iface,vtbl,22); Console.WriteLine();
        Marshal.Release(iface); Marshal.Release(unk);
    }
}
