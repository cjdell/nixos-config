using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

class PinDump {
    static IMoniker FindPctv(string catGuid){
        Guid cat=new Guid(catGuid); object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        ICreateDevEnum de=(ICreateDevEnum)o; IEnumMoniker em; if(de.CreateClassEnumerator(ref cat,out em,0)!=0) return null;
        IMoniker[] m=new IMoniker[1];
        while(em.Next(1,m,IntPtr.Zero)==0){ string nm=""; try{object b;Guid bid=typeof(IPropertyBag).GUID;m[0].BindToStorage(null,null,ref bid,out b);IPropertyBag bag=(IPropertyBag)b;object v;bag.Read("FriendlyName",out v,IntPtr.Zero);nm=Convert.ToString(v);Marshal.ReleaseComObject(b);}catch{}
            if(nm.ToLower().IndexOf("pctv")>=0) return m[0]; Marshal.ReleaseComObject(m[0]); }
        return null;
    }
    static IBaseFilter Bind(IMoniker m){ Guid ibf=typeof(IBaseFilter).GUID; object o=null; if(m==null) return null; m.BindToObject(null,null,ref ibf,out o); return (IBaseFilter)o; }
    static string Sub(Guid g){ string s=g.ToString();
        if(s=="73646976-0000-0010-8000-00aa00389b71") return "MEDIATYPE_Video";
        if(s=="73647561-0000-0010-8000-00aa00389b71") return "MEDIATYPE_Audio";
        if(s=="e436eb7e-524f-11ce-9f53-0020af0ba770") return "FORMAT_VideoInfo";
        if(s=="e06d80e3-db46-11cf-b4d1-00805f6cbbea") return "FORMAT_WaveFormatEx";
        if(s.EndsWith("-0000-0010-8000-00aa00389b71")){ // fourcc
            int f=int.Parse(s.Substring(0,8),System.Globalization.NumberStyles.HexNumber);
            char[] c=new char[4]; for(int i=0;i<4;i++) c[i]=(char)((f>>(8*i))&0xff); return "fourcc'"+new string(c)+"'";
        }
        return s;
    }
    static void DumpFilter(string tag, IBaseFilter f){
        if(f==null){Console.WriteLine(tag+": not present");return;}
        IEnumPins ep; f.EnumPins(out ep); IPin[] ps=new IPin[1]; int got;
        Console.WriteLine("== "+tag);
        while(ep.Next(1,ps,out got)==0&&got==1){
            PIN_INFO pi; ps[0].QueryPinInfo(out pi); int dir; ps[0].QueryDirection(out dir);
            Console.WriteLine("  pin '"+pi.name+"' "+(dir==0?"IN":"OUT"));
            IntPtr et; int hr=ps[0].EnumMediaTypes(out et);
            if(hr==0 && et!=IntPtr.Zero){
                IEnumMediaTypes emt=(IEnumMediaTypes)Marshal.GetObjectForIUnknown(et);
                IntPtr buf=Marshal.AllocHGlobal(IntPtr.Size); int n;
                int cnt=0;
                while(emt.Next(1,buf,out n)==0 && n==1 && cnt<8){
                    AM_MEDIA_TYPE mt=(AM_MEDIA_TYPE)Marshal.PtrToStructure(Marshal.ReadIntPtr(buf),typeof(AM_MEDIA_TYPE));
                    string extra="";
                    if(mt.pbFormat!=IntPtr.Zero){
                        if(mt.formattype==new Guid("e436eb7e-524f-11ce-9f53-0020af0ba770")){
                            VIDEOINFOHEADER vih=(VIDEOINFOHEADER)Marshal.PtrToStructure(mt.pbFormat,typeof(VIDEOINFOHEADER));
                            extra=" "+vih.bmiHeader.biWidth+"x"+vih.bmiHeader.biHeight+" bits="+vih.bmiHeader.biBitCount+" comp="+vih.bmiHeader.biCompression+" fps="+(vih.AvgTimePerFrame!=0?(10000000.0/vih.AvgTimePerFrame).ToString("0.##"):"?");
                        } else if(mt.formattype==new Guid("e06d80e3-db46-11cf-b4d1-00805f6cbbea")){
                            WAVEFORMATEX wf=(WAVEFORMATEX)Marshal.PtrToStructure(mt.pbFormat,typeof(WAVEFORMATEX));
                            extra=" tag="+wf.wFormatTag+" ch="+wf.nChannels+" rate="+wf.nSamplesPerSec+" bits="+wf.wBitsPerSample;
                        }
                    }
                    Console.WriteLine("      "+Sub(mt.majortype)+" / "+Sub(mt.subtype)+" cbFormat="+mt.cbFormat+extra);
                    cnt++;
                }
                Marshal.FreeHGlobal(buf);
                Marshal.ReleaseComObject(emt);
            }
            Marshal.ReleaseComObject(ps[0]);
        }
        Marshal.ReleaseComObject(f);
    }
    [STAThread]
    static void Main(){
        DumpFilter("CAPTURE", Bind(FindPctv("65E8773D-8F56-11D0-A3B9-00A0C9223196")));
        DumpFilter("XBAR", Bind(FindPctv("A799A801-A46D-11D0-A18C-00A02401DCD4")));
        DumpFilter("TVTUNER", Bind(FindPctv("A799A800-A46D-11D0-A18C-00A02401DCD4")));
        DumpFilter("TVAUDIO", Bind(FindPctv("A799A802-A46D-11D0-A18C-00A02401DCD4")));
        DumpFilter("AUDIOCAP", Bind(FindPctv("33D9A762-90C8-11D0-BD43-00A0C911CE86")));
    }
}
