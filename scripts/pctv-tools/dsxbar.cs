using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid pType, out IEnumMoniker ppEnumMoniker, int dwFlags); }

[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] out object v, IntPtr err); [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] ref object v); }

[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IBaseFilter { }

[ComImport, Guid("C6E13370-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAMCrossbar {
    [PreserveSig] int get_PinCounts(out int o, out int i);
    [PreserveSig] int get_CanRoute(int o, int i, out int can);
    [PreserveSig] int get_IsRoutedTo(int o, out int i);
    [PreserveSig] int get_CrossbarPinInfo(int isInputPin, int pinIndex, out int related, out int physType);
    [PreserveSig] int Route(int o, int i);
}

[ComImport, Guid("C6E13350-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAMAnalogVideoDecoder {
    [PreserveSig] int get_AvailableTVFormats(out int f);
    [PreserveSig] int put_TVFormat(int f);
    [PreserveSig] int get_TVFormat(out int f);
}

class DSXbar {
    static string Phys(int t) {
        switch (t) {
            case 1: return "Video_Tuner";
            case 2: return "Video_Composite";
            case 3: return "Video_SVideo";
            case 4: return "Video_RGB";
            case 4096: return "Audio_Tuner";
            case 4097: return "Audio_Line";
            case 4098: return "Audio_Mic";
            case 4099: return "Audio_AesDigital";
            case 4100: return "Audio_Spdif";
            case 4101: return "Audio_Aux";
        }
        return "rawtype_" + t;
    }
    static string Std(int s) {
        if (s == 0) return "None";
        string r = "";
        if ((s & 0x01)!=0) r += "NTSC_M ";
        if ((s & 0x02)!=0) r += "NTSC_M_J ";
        if ((s & 0x04)!=0) r += "NTSC_433 ";
        if ((s & 0x10)!=0) r += "PAL_B ";
        if ((s & 0x20)!=0) r += "PAL_D ";
        if ((s & 0x40)!=0) r += "PAL_G ";
        if ((s & 0x80)!=0) r += "PAL_H ";
        if ((s & 0x100)!=0) r += "PAL_I ";
        if ((s & 0x200)!=0) r += "PAL_M ";
        if ((s & 0x400)!=0) r += "PAL_N ";
        if ((s & 0x800)!=0) r += "PAL_60 ";
        if ((s & 0x1000)!=0) r += "SECAM_B ";
        if ((s & 0x2000)!=0) r += "SECAM_D ";
        if ((s & 0x4000)!=0) r += "SECAM_G ";
        if ((s & 0x8000)!=0) r += "SECAM_H ";
        if ((s & 0x10000)!=0) r += "SECAM_K ";
        if ((s & 0x20000)!=0) r += "SECAM_K1 ";
        if ((s & 0x40000)!=0) r += "SECAM_L ";
        if ((s & 0x80000)!=0) r += "SECAM_L1 ";
        if ((s & 0x100000)!=0) r += "PAL_N_COMBO ";
        return r.Trim() + " (0x" + s.ToString("x") + ")";
    }
    static IEnumMoniker EnumCat(string guid) {
        Guid cat = new Guid(guid);
        object o = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de = (ICreateDevEnum)o;
        IEnumMoniker em;
        int hr = de.CreateClassEnumerator(ref cat, out em, 0);
        if (hr != 0) return null;
        return em;
    }
    static string Name(IMoniker m) {
        try { object b; Guid bid = typeof(IPropertyBag).GUID; m.BindToStorage(null,null,ref bid,out b);
              IPropertyBag bag=(IPropertyBag)b; object v; bag.Read("FriendlyName", out v, IntPtr.Zero);
              Marshal.ReleaseComObject(b); return Convert.ToString(v); }
        catch { return "<unnamed>"; }
    }
    static void Main(string[] args) {
        int wantRoute = -1;
        if (args.Length >= 2 && args[0] == "route") wantRoute = int.Parse(args[1]);

        Console.WriteLine("### CROSSBAR (AM_KSCATEGORY_CROSSBAR) ###");
        IEnumMoniker em = EnumCat("A799A801-A46D-11D0-A18C-00A02401DCD4");
        if (em != null) {
            IMoniker[] m = new IMoniker[1];
            while (em.Next(1, m, IntPtr.Zero) == 0) {
                Console.WriteLine("Filter: " + Name(m[0]));
                try {
                    Guid ibf = typeof(IBaseFilter).GUID; object fobj; m[0].BindToObject(null,null,ref ibf,out fobj);
                    IAMCrossbar cb = (IAMCrossbar)fobj;
                    int oc, ic; cb.get_PinCounts(out oc, out ic);
                    Console.WriteLine("  outputs=" + oc + " inputs=" + ic);
                    for (int i = 0; i < oc; i++) { int r=-1; cb.get_IsRoutedTo(i, out r);
                        Console.WriteLine("  OUT[" + i + "] currently <- IN[" + r + "]"); }
                    for (int i = 0; i < ic; i++) { int rel, pt; cb.get_CrossbarPinInfo(1, i, out rel, out pt);
                        Console.WriteLine("  IN[" + i + "] = " + Phys(pt)); }
                    if (wantRoute >= 0) {
                        int target = -1;
                        for (int i = 0; i < ic; i++) { int rel, pt; cb.get_CrossbarPinInfo(1, i, out rel, out pt); if (pt == wantRoute) { target = i; break; } }
                        if (target < 0) Console.WriteLine("  !! no input with type " + wantRoute);
                        else { int hr = cb.Route(0, target); Console.WriteLine("  Route(OUT0, IN" + target + ") -> hr=0x" + hr.ToString("x8")); }
                    }
                } catch (Exception ex) { Console.WriteLine("  (IAMCrossbar unavailable: " + ex.Message + ")"); }
                Marshal.ReleaseComObject(m[0]);
            }
        } else Console.WriteLine("(no crossbar category)");

        Console.WriteLine();
        Console.WriteLine("### CAPTURE FILTER DECODER ###");
        IEnumMoniker ec = EnumCat("65E8773D-8F56-11D0-A3B9-00A0C9223196");
        if (ec != null) {
            IMoniker[] m = new IMoniker[1];
            while (ec.Next(1, m, IntPtr.Zero) == 0) {
                Console.WriteLine("Filter: " + Name(m[0]));
                try {
                    Guid ibf = typeof(IBaseFilter).GUID; object fobj; m[0].BindToObject(null,null,ref ibf,out fobj);
                    try {
                        IAMAnalogVideoDecoder d = (IAMAnalogVideoDecoder)fobj;
                        int avail, cur; d.get_AvailableTVFormats(out avail); d.get_TVFormat(out cur);
                        Console.WriteLine("  AvailableTVFormats: " + Std(avail));
                        Console.WriteLine("  Current TVFormat  : " + Std(cur));
                    } catch (Exception ex2) { Console.WriteLine("  (no IAMAnalogVideoDecoder: " + ex2.Message + ")"); }
                    try {
                        IAMCrossbar cb2 = (IAMCrossbar)fobj;
                        int oc, ic; cb2.get_PinCounts(out oc, out ic);
                        Console.WriteLine("  capture filter ALSO has IAMCrossbar: outputs=" + oc + " inputs=" + ic);
                        for (int i = 0; i < oc; i++) { int r=-1; cb2.get_IsRoutedTo(i, out r); Console.WriteLine("    OUT[" + i + "] <- IN[" + r + "]"); }
                        for (int i = 0; i < ic; i++) { int rel, pt; cb2.get_CrossbarPinInfo(1, i, out rel, out pt); Console.WriteLine("    IN[" + i + "] = " + Phys(pt)); }
                    } catch { }
                } catch (Exception ex) { Console.WriteLine("  bind failed: " + ex.Message); }
                Marshal.ReleaseComObject(m[0]);
            }
        }
    }
}
