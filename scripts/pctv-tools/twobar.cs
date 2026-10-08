using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class TwoBar {
    static IMoniker FindPctv(string catGuid){
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if(de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while(em.Next(1,m,IntPtr.Zero)==0){ string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0) return m[0]; Marshal.ReleaseComObject(m[0]); }
        return null;
    }
    static object Bind(IMoniker m){ Guid ibf=typeof(IBaseFilter).GUID; object o=null; m.BindToObject(null,null,ref ibf,out o); return o; }
    [STAThread]
    static void Main(){
        IMoniker m=FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4");
        object a=Bind(m);
        Console.WriteLine("read B before route:"); object b=Bind(m); PctvRoute.Select(b,null,false); Marshal.ReleaseComObject(b);
        Console.WriteLine("route A -> SVideo:"); PctvRoute.Select(a,"Video SVideo In",true);
        Console.WriteLine("read B after route (same-process new instance):"); object b2=Bind(m); PctvRoute.Select(b2,null,false); Marshal.ReleaseComObject(b2);
        Console.WriteLine("release A"); Marshal.ReleaseComObject(a);
        Console.WriteLine("read C after A released (fresh instance):"); object c=Bind(m); PctvRoute.Select(c,null,false); Marshal.ReleaseComObject(c);
    }
}
