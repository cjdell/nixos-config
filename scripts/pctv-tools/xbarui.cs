using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid pType, out IEnumMoniker ppEnumMoniker, int dwFlags); }
[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] out object v, IntPtr err); [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] ref object v); }
[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IBaseFilter { }
[StructLayout(LayoutKind.Sequential)]
struct CAUUID { public int cElems; public IntPtr pElems; }
[ComImport, Guid("B196B28B-BAB4-101A-B69C-00AA00341D07"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISpecifyPropertyPages { [PreserveSig] int GetPages(out CAUUID p); }

class XbarUI {
    [DllImport("ole32.dll")] static extern int OleInitialize(IntPtr p);
    [DllImport("ole32.dll")] static extern void OleUninitialize();
    [DllImport("oleaut32.dll", CharSet=CharSet.Unicode)]
    static extern int OleCreatePropertyFrame(IntPtr hwndOwner, int x, int y, string caption, uint cObjects, IntPtr ppUnk, uint cPages, IntPtr lpPageClsID, int lcid, int dwReserved, IntPtr lpvReserved);
    [STAThread]
    static void Main() {
        OleInitialize(IntPtr.Zero);
        Guid cat=new Guid("A799A801-A46D-11D0-A18C-00A02401DCD4");
        object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; de.CreateClassEnumerator(ref cat,out em,0);
        IMoniker[] m=new IMoniker[1]; object fobj=null;
        while (em.Next(1,m,IntPtr.Zero)==0) {
            string nm="";
            try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if (nm.ToLower().IndexOf("pctv")>=0) { Guid ibf=typeof(IBaseFilter).GUID; m[0].BindToObject(null,null,ref ibf,out fobj); break; }
            Marshal.ReleaseComObject(m[0]);
        }
        if (fobj==null) { Console.WriteLine("xbar not found"); return; }
        try { ISpecifyPropertyPages sp=(ISpecifyPropertyPages)fobj; CAUUID c; sp.GetPages(out c);
              Console.WriteLine("pages="+c.cElems); for(int i=0;i<c.cElems;i++){ Guid g=(Guid)Marshal.PtrToStructure(new IntPtr(c.pElems.ToInt64()+i*16),typeof(Guid)); Console.WriteLine("  page="+g); } } catch(Exception ex){ Console.WriteLine("pages err: "+ex.Message); }
        IntPtr unk=Marshal.GetIUnknownForObject(fobj);
        IntPtr arr=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(arr,unk);
        Console.WriteLine("showing property frame...");
        int hr=OleCreatePropertyFrame(IntPtr.Zero, 20, 20, "PCTV DiB BDA Analog Xbar", 1, arr, 0, IntPtr.Zero, 0, 0, IntPtr.Zero);
        Console.WriteLine("frame closed hr=0x"+hr.ToString("x8"));
        OleUninitialize();
    }
}
