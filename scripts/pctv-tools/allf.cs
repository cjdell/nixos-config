using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid pType, out IEnumMoniker ppEnumMoniker, int dwFlags); }
[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] out object v, IntPtr err); [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] ref object v); }

class AllF {
    static ICreateDevEnum DevEnum(){ return (ICreateDevEnum)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86"))); }
    static string Name(IMoniker m){ try{object b;Guid bid=typeof(IPropertyBag).GUID;m.BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);Marshal.ReleaseComObject(b);return Convert.ToString(v);}catch{return null;} }
    static Guid? CatGuid(IMoniker m){ try{object b;Guid bid=typeof(IPropertyBag).GUID;m.BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("CLSID",out v,IntPtr.Zero);Marshal.ReleaseComObject(b); string s=Convert.ToString(v); if(string.IsNullOrEmpty(s)) return null; return new Guid(s);}catch{return null;} }

    [STAThread]
    static void Main(){
        string pat = "pctv";
        ICreateDevEnum de=DevEnum();
        Guid AMCAT=new Guid("DA4E3DA0-D07D-11d0-BD50-00A0C911CE86");
        IEnumMoniker cats; int hr=de.CreateClassEnumerator(ref AMCAT,out cats,0);
        Console.WriteLine("category enum hr=0x"+hr.ToString("x8"));
        if(hr!=0){ Console.WriteLine("no categories"); return; }
        IMoniker[] cm=new IMoniker[1]; int total=0;
        while(cats.Next(1,cm,IntPtr.Zero)==0){
            string cname=Name(cm[0]); Guid? cg=CatGuid(cm[0]);
            if(cg==null){ Marshal.ReleaseComObject(cm[0]); continue; }
            if(cname==null) cname="<unnamed>";
            Guid cgg=cg.Value;
            int n=0;
            try{
                IEnumMoniker em; de.CreateClassEnumerator(ref cgg,out em,0);
                IMoniker[] fm=new IMoniker[1];
                while(em.Next(1,fm,IntPtr.Zero)==0){ string fn=Name(fm[0]); n++; total++;
                    if(fn!=null && fn.ToLower().IndexOf(pat)>=0) Console.WriteLine("["+cname+" / "+cgg+"]  FILTER: "+fn);
                    Marshal.ReleaseComObject(fm[0]);
                }
            }catch{}
            if(n>0 && cname.ToLower().IndexOf("vidcap")>=0) Console.WriteLine("  (category "+cname+" has "+n+")");
            Marshal.ReleaseComObject(cm[0]);
        }
        Console.WriteLine("scanned "+total+" filters in all categories");
    }
}
