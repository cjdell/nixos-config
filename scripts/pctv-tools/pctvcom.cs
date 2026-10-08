// Shared COM/DirectShow interop declarations for the PCTV capture tools.
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid pType, out IEnumMoniker ppEnumMoniker, int dwFlags); }
[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyBag { [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] out object v, IntPtr err); [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string n, [MarshalAs(UnmanagedType.Struct)] ref object v); }

[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
struct PIN_INFO { public IntPtr pFilter; public int dir; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string name; }
[ComImport, Guid("56a86891-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPin {
    [PreserveSig] int Connect(IPin r, IntPtr mt); [PreserveSig] int ReceiveConnection(IPin c, IntPtr mt);
    [PreserveSig] int Disconnect(); [PreserveSig] int ConnectedTo(out IPin p);
    [PreserveSig] int ConnectionMediaType(IntPtr mt); [PreserveSig] int QueryPinInfo(out PIN_INFO i);
    [PreserveSig] int QueryDirection(out int d); [PreserveSig] int QueryId(out IntPtr id);
    [PreserveSig] int QueryAccept(IntPtr mt); [PreserveSig] int EnumMediaTypes(out IntPtr e);
    [PreserveSig] int QueryInternalConnections(IntPtr a, ref int n);
    [PreserveSig] int EndOfStream(); [PreserveSig] int BeginFlush(); [PreserveSig] int EndFlush(); [PreserveSig] int NewSegment(long a, long b, double r);
}
[ComImport, Guid("56a86892-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IEnumPins { [PreserveSig] int Next(int c, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] IPin[] p, out int f); [PreserveSig] int Skip(int c); [PreserveSig] int Reset(); [PreserveSig] int Clone(out IEnumPins e); }
[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IBaseFilter {
    [PreserveSig] int GetClassID(out Guid g); [PreserveSig] int Stop(); [PreserveSig] int Pause(); [PreserveSig] int Run(long t);
    [PreserveSig] int GetState(int ms, out int st); [PreserveSig] int SetSyncSource(IntPtr c); [PreserveSig] int GetSyncSource(out IntPtr c);
    [PreserveSig] int EnumPins(out IEnumPins e); [PreserveSig] int FindPin([MarshalAs(UnmanagedType.LPWStr)] string id, out IPin p);
    [PreserveSig] int QueryFilterInfo(IntPtr i); [PreserveSig] int JoinFilterGraph(IntPtr g, [MarshalAs(UnmanagedType.LPWStr)] string n);
    [PreserveSig] int QueryVendorInfo(out IntPtr n);
}
[ComImport, Guid("56a868a9-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGraphBuilder {
    [PreserveSig] int AddFilter(IBaseFilter f, [MarshalAs(UnmanagedType.LPWStr)] string name);
    [PreserveSig] int RemoveFilter(IBaseFilter f);
    [PreserveSig] int EnumFilters(out IntPtr e);
    [PreserveSig] int FindFilterByName([MarshalAs(UnmanagedType.LPWStr)] string n, out IBaseFilter f);
    [PreserveSig] int ConnectDirect(IPin o, IPin i, IntPtr mt);
    [PreserveSig] int Reconnect(IPin p);
    [PreserveSig] int Disconnect(IPin p);
    [PreserveSig] int SetDefaultSyncSource();
    [PreserveSig] int Connect(IPin o, IPin i);
}
[ComImport, Guid("56a868b1-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMediaControl {
    [PreserveSig] int GetTypeInfoCount(out int c);
    [PreserveSig] int GetTypeInfo(int i, int lcid, out IntPtr ti);
    [PreserveSig] int GetIDsOfNames(ref Guid riid, [MarshalAs(UnmanagedType.LPArray, ArraySubType=UnmanagedType.LPWStr)] string[] names, int c, int lcid, [MarshalAs(UnmanagedType.LPArray)] int[] ids);
    [PreserveSig] int Invoke(int dispId, ref Guid riid, int lcid, short flags, IntPtr dp, IntPtr vr, IntPtr ei, IntPtr ae);
    [PreserveSig] int Run(); [PreserveSig] int Pause(); [PreserveSig] int Stop();
    [PreserveSig] int GetState(int ms, out int st);
}
[ComImport, Guid("6B652FFF-11FE-4FCE-92AD-0266B5D7C78F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISampleGrabber {
    [PreserveSig] int SetOneShot([MarshalAs(UnmanagedType.Bool)] bool b);
    [PreserveSig] int SetMediaType(IntPtr mt);
    [PreserveSig] int GetConnectedMediaType(IntPtr mt);
    [PreserveSig] int SetBufferSamples([MarshalAs(UnmanagedType.Bool)] bool b);
    [PreserveSig] int GetCurrentBuffer(ref int size, IntPtr buf);
    [PreserveSig] int GetCurrentSample(out IntPtr s);
    [PreserveSig] int SetCallback(IntPtr cb, int m);
}
[ComImport, Guid("C6E13350-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAMAnalogVideoDecoder {
    [PreserveSig] int get_AvailableTVFormats(out int f);
    [PreserveSig] int put_TVFormat(int f);
    [PreserveSig] int get_TVFormat(out int f);
}
[StructLayout(LayoutKind.Sequential)]
struct AM_MEDIA_TYPE { public Guid majortype, subtype; public int fixedSize, temporal; public int sampleSize; public Guid formattype; public IntPtr pUnk; public int cbFormat; public IntPtr pbFormat; }
[StructLayout(LayoutKind.Sequential)]
struct RECT { public int left, top, right, bottom; }
[StructLayout(LayoutKind.Sequential)]
struct BITMAPINFOHEADER { public int biSize; public int biWidth; public int biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
[StructLayout(LayoutKind.Sequential)]
struct VIDEOINFOHEADER { public RECT rcSource, rcTarget; public int dwBitRate, dwBitErrorRate; public long AvgTimePerFrame; public BITMAPINFOHEADER bmiHeader; }

[ComImport, Guid("93E5A4E0-2D50-11d2-ABFA-00A0C9C6E38D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICaptureGraphBuilder2 {
    [PreserveSig] int SetFiltergraph(IGraphBuilder g);
    [PreserveSig] int GetFiltergraph(out IGraphBuilder g);
    [PreserveSig] int SetOutputFileName(ref Guid pType, [MarshalAs(UnmanagedType.LPWStr)] string file, out IBaseFilter mux, out IFileSinkFilter sink);
    [PreserveSig] int FindInterface(ref Guid cat, ref Guid type, IntPtr f, ref Guid iid, out IntPtr ret);
    [PreserveSig] int RenderStream(ref Guid cat, ref Guid type, IntPtr source, IBaseFilter compressor, IBaseFilter renderer);
    [PreserveSig] int ControlStream(ref Guid cat, ref Guid type, IBaseFilter filter, long start, long stop, short startCookie, short stopCookie);
    [PreserveSig] int AllocCapFile([MarshalAs(UnmanagedType.LPWStr)] string file, long size);
    [PreserveSig] int CopyCaptureFile([MarshalAs(UnmanagedType.LPWStr)] string oldf, [MarshalAs(UnmanagedType.LPWStr)] string newf, int allow, IntPtr cb);
    [PreserveSig] int FindPin(IntPtr source, int dir, ref Guid cat, ref Guid type, [MarshalAs(UnmanagedType.Bool)] bool unconnected, out IPin pin);
}
[ComImport, Guid("A2104830-7C70-11CF-8BCE-00AA00A3F1A6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IFileSinkFilter {
    [PreserveSig] int SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr mt);
    [PreserveSig] int GetCurFile(out IntPtr name, IntPtr mt);
}

[ComImport, Guid("89c31040-846b-11ce-97d3-00aa0055595a"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IEnumMediaTypes { [PreserveSig] int Next(int c, IntPtr mt, out int f); [PreserveSig] int Skip(int c); [PreserveSig] int Reset(); [PreserveSig] int Clone(out IEnumMediaTypes e); }
[StructLayout(LayoutKind.Sequential, Pack=1)]
struct WAVEFORMATEX { public short wFormatTag, nChannels; public int nSamplesPerSec, nAvgBytesPerSec; public short nBlockAlign, wBitsPerSample, cbSize; }

[ComImport, Guid("C6E13370-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAMCrossbar {
    [PreserveSig] int get_PinCounts(out int o, out int i);
    [PreserveSig] int get_CanRoute(int o, int i, out int can);
    [PreserveSig] int get_IsRoutedTo(int o, out int i);
    [PreserveSig] int get_CrossbarPinInfo(int isInputPin, int pinIndex, out int related, out int physType);
    [PreserveSig] int Route(int o, int i);
}
