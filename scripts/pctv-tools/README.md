# PCTV 320cx guest tooling (Win7 VM)

C# sources for the diagnostic/capture tools used against the Pinnacle PCTV 320cx in the
`win7` VM. They were previously only present as `.exe`/`.cs` inside the guest
(`C:\Users\Chris`); this directory preserves the sources so the next session does not have
to rebuild them from scratch.

All of these run **inside the Win7 guest**, built with the guest's own compiler — no SDKs,
no downloads (the guest has **.NET 3.5 / `csc.exe` only**, no .NET 4):

```sh
# compile (64-bit; use Framework\v3.5\csc.exe for 32-bit)
C:\Windows\Microsoft.NET\Framework64\v3.5\csc.exe /nologo /platform:x64 \
    /main:MainClass /out:C:\Users\Chris\tool.exe  <sources...>

# copy a source in / a result out from the host
./scripts/pctv-win7-ssh.sh --put scripts/pctv-tools/tool.cs 'C:/Users/Chris/tool.cs'
./scripts/pctv-win7-ssh.sh --get 'C:/Users/Chris/frame.raw' /tmp/frame.raw
./scripts/pctv-win7-ssh.sh 'C:\Users\Chris\tool.exe args'
```

`pctvcom.cs` holds the shared COM/DirectShow interop; most other files compile together
with it (`/main:` picks the entry point when several `Main`s are linked).

## Tools

| File | Entry point | Purpose |
| --- | --- | --- |
| `pctvcom.cs` | — | Shared interop: `ICreateDevEnum`, `IBaseFilter`, `IGraphBuilder`, `IMediaControl`, `IAMAnalogVideoDecoder`, `ISampleGrabber`, `ICaptureGraphBuilder2`, media-type structs. |
| `dsenum.cs` | `DsEnum` | Enumerate DirectShow video/audio input devices. |
| `dstree.cs` | `DsTree` | List PCTV filters and their pins (dir + name). |
| `dsiid.cs` | `DsIID` | `QueryInterface` each PCTV filter/pin for the BDA/DirectShow control interfaces. |
| `pindump.cs` | `PinDump` | Dump each pin's `IEnumMediaTypes` (format/fourcc/size/fps, audio tags). |
| `allf.cs` | `AllF` | Enumerate **every** registered DirectShow filter category and grep for `pctv` (finds software filters, not KS device filters). |
| `pctvroute.cs` | `PctvRoute` / `Select()` | **Property-page router.** Opens the crossbar page with `OleCreatePropertyFrame`, selects `Video SVideo In` / `Video Composite In` / `Video Tuner In`, clicks Apply/OK. Also `read` and `test` modes. |
| `mincap.cs` | `MinCap` | Minimal capture attempt: crossbar → capture (+ optional tuner), optional audio path, route, `Run`, poll a SampleGrabber. |
| `tuncap.cs` | `TunCap` | Capture attempt that drives the tuner's `IAMTVTuner` (wrong base-interface layout — see doc). |
| `vtprobe.cs` | `VtProbe` | Raw vtable scan of the tuner's `IAMTVTuner` interface to find the real input-select slots. |
| `pc.cs` / `pc2.cs` | `Pc` / `Pc2` | Typed / raw-slot probes of the tuner input-connection methods. |
| `ksx.cs` | `Ksx` | Probe every PCTV filter/pin for `IKsPropertySet`/`IKsControl` and the KS property sets (incl. the crossbar set). |
| `ksprobe.cs` | `KsProbe` | KS `KSPROPERTY_CROSSBAR_*` probe (CAPS / PININFO / CAN_ROUTE / ROUTE) + `ROUTE SET`. |
| `probe.cs` | `Probe` | Broad interface probe across all PCTV filters/pins (crossbar, KS, tuner, BDA). |
| `xbar2.cs` | `Xbar2` | Check whether `IAMCrossbar` appears **after** the filter is added to a graph / connected. |
| `twobar.cs` | `TwoBar` | Test whether a route on one crossbar instance is visible from another. |
| `pagetest.cs` | `PageTest` | Interactive property-page driver: dumps controls, exercises `CB_SETCURSEL` / `CBM_SELCHANGE` / Apply, verifies which notification target works. |
| `pageauto.cs` | `PageAuto` | `OleCreatePropertyFrame` + window discovery + raw `CoCreateInstance` interface probe of the page CLSID. |
| `cgb.cs` / `rcap.cs` | `CgbTest` / `Rcap` | `ICaptureGraphBuilder2` graphs: `SetOutputFileName` (AVI mux) and `RenderStream`. |
| `pctvframe.cs` | `PctvFrame` | Graph + route + SampleGrabber frame grab (writes a raw frame). |
| `xbarui.cs` | `XbarUI` | (winexe) Show the crossbar property page on the interactive session. No stdout over ssh. |
| `dsbda.cs`, `dsprobe.cs`, `dsroute.cs`, `dsxbar.cs` | — | Earlier BDA/xbar probes (kept for reference; largely superseded). |

## Verdict

See `docs/pctv-320cx.md` §5.5. Short version: the property page **can** be driven
programmatically, but the analog capture still never streams (the driver issues no bulk-IN
URBs and `Run()` fails), and the driver bugchecks the kernel (`0x0000000A`). Do **not**
run repeated capture attempts on the live VM without expecting a crash/reboot.
