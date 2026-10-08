using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICreateDevEnum {
    [PreserveSig] int CreateClassEnumerator([In] ref Guid pType, out IEnumMoniker ppEnumMoniker, int dwFlags);
}

[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyBag {
    [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] out object v, IntPtr err);
    [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] ref object v);
}

class DSEnum {
    static void Dump(string title, Guid cat) {
        Console.WriteLine("== " + title + " ==");
        object o = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de = (ICreateDevEnum)o;
        IEnumMoniker em;
        int hr = de.CreateClassEnumerator(ref cat, out em, 0);
        if (hr != 0 || em == null) { Console.WriteLine("  (none / hr=0x" + hr.ToString("x8") + ")"); return; }
        IMoniker[] m = new IMoniker[1];
        IntPtr fetched = IntPtr.Zero;
        while (em.Next(1, m, fetched) == 0) {
            string name = "<unnamed>", disp = null;
            try {
                object bagObj; Guid bid = typeof(IPropertyBag).GUID;
                m[0].BindToStorage(null, null, ref bid, out bagObj);
                IPropertyBag bag = (IPropertyBag)bagObj;
                object v;
                if (bag.Read("FriendlyName", out v, IntPtr.Zero) == 0) name = Convert.ToString(v);
                object v2;
                if (bag.Read("Description", out v2, IntPtr.Zero) == 0) disp = Convert.ToString(v2);
                Marshal.ReleaseComObject(bagObj);
            } catch (Exception ex) { name = "<err:" + ex.Message + ">"; }
            Console.WriteLine("  " + name + (disp != null ? "  [" + disp + "]" : ""));
            Marshal.ReleaseComObject(m[0]);
        }
        Marshal.ReleaseComObject(em); Marshal.ReleaseComObject(o);
    }
    static void Main() {
        Dump("Video Input Devices", new Guid("860BB310-5D01-11d0-BD3B-00A0C911CE86"));
        Dump("Audio Input Devices", new Guid("33D9A762-90C8-11d0-BD43-00A0C911CE86"));
    }
}
