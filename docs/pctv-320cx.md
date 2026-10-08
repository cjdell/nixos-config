# Pinnacle PCTV 320cx — findings and plan

Status (superseded 2026-10-06 evening — see §5.5): **The property page *can* be driven
programmatically, so the "select the input by hand" blocker in §5.4.5 is solved — but the
analog capture still yields no frames, and the driver bugchecks the kernel. §5.4's
conclusion that routing was the only blocker is **superseded and misleading**. Go to §5.5
for the current state and the full list of what was tried and failed.**

Earlier status (kept for history): **USB passthrough transport FIXED and the guest driver
now starts cleanly (all PCTV nodes `ERR=0`, DirectShow capture sources enumerate) — see
§5.3.** The
card is a *hybrid* USB device (digital DVB-T + analog composite/S-Video/audio capture), but
the analog side is supported **only by Pinnacle's closed Windows driver**. Linux drives only
the DVB-T side. Plan: capture composite+audio via **USB passthrough to a Windows 7 VM**
using the original Pinnacle driver.

Host of interest: `macbook-pro-2009-nixos` (NixOS, `MacBookPro5,1`).

---

## 1. Goal

Make **high-quality captures of composite video + audio** from the card's pigtail
(3× RCA phono — composite video + stereo audio — plus an S-Video connector).

## 2. The hardware, as Linux sees it

- USB ID `2304:022e` — `Pinnacle Systems, Inc. PCTV 320cx`
  (`lsusb` reports product string "PCTV 320cx", manufacturer "Pinnacle system").
- Kernel names it **"Pinnacle Expresscard 320cx"** and binds it to the **`dvb_usb_dib0700`**
  driver. It enumerates cold → warm (loads firmware `dvb-usb-dib0700-1.20.fw`).
- Digital path (working today):
  - Frontend: **DiBcom 7000PC** (dib7000p) — DVB-T only.
  - Tuner: **xc2028/xc3028** (RF hybrid tuner; firmware `xc3028-v27.fw` loads fine).
  - IR remote receiver (`rc0`) also registers.
  - Result: `/dev/dvb/adapter0` (demux/dvr/frontend/net), **no `/dev/video*`**.

### Physical / bus findings (important)

- Despite the "ExpressCard" name, the device enumerates entirely over **USB** on the
  built-in EHCI controller (`/devices/.../0000:00:06.1/usb2/2-3`).
- The Mac's actual ExpressCard/34 **PCIe** slot is real and wired:
  - PCIe bridge `0000:00:17.0` carries a secondary bus window `[06-0d]`.
  - acpiphp hotplug slot **`5`** = `0000:06:00` (`/sys/bus/pci/slots/5`).
  - It consistently reports `adapter=0` (no card present) and `power=0`, and refuses to
    stay powered on (`echo 1 > power` reverts to 0). This is a known Linux quirk on the
    MCP79 MacBook Pro; irrelevant to this device.
- Conclusion: the PCTV 320cx is **USB-only**. It is **not** split USB(DVB)+PCIe(analog).
  Its "ExpressCard" naming is marketing; there is no PCIe function to bring up.

## 3. The driver package proves it is a hybrid (analog + digital)

The original Windows driver zip (`PCTV 72e 320cx.zip`) contains `PCTV.inf` which binds
`USB\VID_2304&PID_022E` → "PCTV 320cx", service `Ltn_hyd7700pc.sys` ("hyd" = hybrid),
described as *"DiBcom DIB7700 based TV tuner device."* It registers, on that **same
single USB device**:

- Digital (BDA): `BdaDigCaptureFilterName` / `BdaDigTunerFilterName`.
- Analog:
  - `AnlgCaptureFilterName` — *Analog Capture*
  - `AnlgXBarFilterName` — *Analog Crossbar* ← composite / S-Video input selector
  - `AnlgTVAudioFilterName`, `AnlgAudioCaptureFilterName`, plus `wdmaudio.inf`
  - `AudioCaptureSupport=1`, `AnalogAmpLimitLevel`
  - Includes `kscaptur.inf` → creates real video-capture (KS) + audio (wdmaudio) devices.

So the phono/S-Video pigtail **does** feed a genuine analog video+audio capture path.
This confirms the device is a hybrid — but that analog path lives **only** inside the
proprietary Pinnacle Windows driver.

## 4. Why Linux cannot do the analog side

- The only Linux driver for this chip is the DVB `dvb_usb_dib0700` driver.
- Source check (`drivers/media/usb/dvb-usb/dib0700_devices.c`): **zero** V4L2 / analog /
  crossbar / composite / S-Video code. It is DVB-only.
- No open-source driver exists for the DIB7700's analog capture, and the chip is obscure
  enough that writing one is not realistic.
- Therefore **no NixOS/Linux software install can produce a `/dev/video*`** for this card.

## 5. Recommended plan: composite/audio capture via Windows 7 VM (USB passthrough)

Because the analog path is Windows-only:

1. **Host (NixOS, `macbook-pro-2009-nixos`):**
   - Install a VM manager (e.g. `virt-manager` + `libvirt`/KVM, or VirtualBox).
   - Create a Windows 7 guest.
   - Pass the PCTV 320cx through to the guest **by USB** (`2304:022e`) — this is a USB
     device, so USB passthrough (not PCI/VFIO) is the mechanism.
2. **Guest (Windows 7):**
   - Install the original Pinnacle driver (`PCTV 72e 320cx.zip`:
     `Ltn_hyd7700pc_64.sys` for 64-bit, or 32-bit `Ltn_hyd7700pc.sys`).
   - The analog crossbar + capture filters then appear; capture composite/audio with
     Pinnacle's software or a WDM/KS capture app (e.g. VirtualDub).
3. **Capture at high quality** from the VM; transfer the resulting file back to the host.

### Gotchas for the Win7 route

- The driver is dated **06/14/2007 (v1.0.0.0)**. Expect it to need relaxed driver
  signing: boot Windows 7 with F8 → "Disable Driver Signature Enforcement", or use
  `bcdedit /set testsigning on` (x64). A 32-bit Win7 guest avoids most signing pain and
  matches the era of the driver better.
- USB passthrough of a DVB/capture device needs the guest to keep the device claimed —
  make sure the host's `dvb_usb_dib0700` driver doesn't grab it first (VM USB passthrough
  normally detaches it from the host automatically). If not, `sudo modprobe -r dvb_usb_dib0700`
  while the VM owns it.
- Performance/real-time: capture and encode happen in the guest; keep the guest on a fast
  disk and disable host CPU features that cause stalls if you see USB timeouts.

### 5.1 Which VM software? — QEMU/KVM + libvirt + virt-manager (not VirtualBox)

**Recommended: QEMU/KVM driven by libvirt + virt-manager.** Do not use VirtualBox here.

Why KVM:

- The host config **already loads `kvm-intel`** (`boot.kernelModules` in
  `machines/macbook-pro-2009/hardware-configuration.nix`), so hardware virtualization is
  already wired up — QEMU needs no kernel modules of its own.
- VirtualBox ships **out-of-tree kernel modules** (`vboxdrv`, `vboxnetadp`) that must be
  rebuilt against every kernel bump (`boot.kernelPackages = linuxPackages_latest` here,
  so they'd churn often). KVM avoids all of that.
- libvirt's **USB passthrough (`<hostdev>`/usb-host) is the right mechanism** for a
  bulk/isochronous capture device like this. It detaches the device from the host kernel
  and hands it wholesale to the guest.
- Crucially for the RE trace (§6): the host can run **`usbmon`** and record the exact
  traffic a USB-passthrough guest generates, because usbmon sees the wire regardless of
  which driver (or VM) owns the device.

Minimal NixOS enablement (host of interest):

```nix
services.libvirtd.enable = true;
users.users.<you>.extraGroups = [ "libvirtd" ];  # then virt-manager / virsh as your user
environment.systemPackages = [ pkgs.virt-manager pkgs.libvirt ]; # virt-manager pulls GTK UI
```

Guest recipe notes:
- Windows 7's **inbox drivers cover emulated IDE disk + e1000/rtl8139 NIC**, so you can
  skip installing VirtIO drivers (which would need a virtio-win ISO inside the guest).
  On 2009-era hardware use the simple emulated devices; KVM is still the hypervisor.
- Use a **32-bit Windows 7** guest to sidestep x64 driver-signing pain and to match the
  2007-era driver; give it ~1–2 GB RAM.
- In virt-manager add the device via *Virtual hardware → Add Hardware → USB Host Device →*
  select `Pinnacle … 2304:022e`. If the host driver grabs it first, either the VM detaches
  it automatically or `sudo modprobe -r dvb_usb_dib0700` while the VM owns it.
- **Avoid SPICE USB redirection (`usb-redir`)** for this device — it is not built for
  streaming capture hardware. Use raw **hostdev** USB passthrough only.

### 5.2 Implemented setup on `macbook-pro-2009-nixos` (2026-09-10)

**Status: transport fixed 2026-10-06; guest driver still failing.** The card is passed
through by USB to the `win7` libvirt domain with the host driver kept away from it, and
QEMU now follows it across re-enumeration on its own (§5.3).

What the live machine revealed (and why the naive approach fails):

- **No IOMMU on this MacBookPro5,1 (NVIDIA MCP79).** `/sys/class/iommu` is empty, no
  DMAR/IVRS, no `vfio`. **VFIO PCI passthrough of a whole USB controller is impossible
  here**, so the device has to stay a USB hostdev. (`0000:00:06.1` EHCI = bus 2 = the
  PCTV; its companion `0000:00:06.0` OHCI = bus 4 = Bluetooth, so a controller pass would
  have dragged the Bluetooth controller in as well.)
- The host `dvb_usb_dib0700` driver must be kept off the card. When it wins the
  re-enumeration race it re-inits/reloads the card and starts a reset/reload loop that
  fights the guest — the VMM "device removed" popups and the up/down-every-second
  behaviour. It is disabled in `machines/macbook-pro-2009/default.nix`: a
  `boot.blacklistedKernelModules` entry **plus** an `install …/bin/false` modprobe guard
  (blacklist alone is alias-only, and udev autoloads via the device alias). Trade-off: the
  Linux DVB-T side of the card is disabled while this is in place.
- The card re-enumerates **twice** per (re)plug: first full-speed on the OHCI companion
  (`usb 4-3`), then high-speed on the EHCI (`usb 2-3`). Both enumerate as `2304:022e`, so
  matching by vendor:product is stable across cold→warm; the udev rule filters on
  `ATTR{speed}=="480"` so only the EHCI enumeration triggers a re-attach.
- **libvirt pins USB hostdevs to a bus/device address.** Even when the XML uses only
  `<vendor>/<product>`, `qemuBuildUSBHostdevDevProps()` resolves it at domain start and
  QEMU gets `usb-host,hostdevice=/dev/bus/usb/<bus>/<dev>` — a fixed path that goes stale
  on re-enumeration (guest sees unplug; QEMU logs `libusb_release_interface: -4
  [NO_DEVICE]`). libvirt 12.2 has no `hostport`/`vendorid` QEMU passthrough.
  QEMU's `usb-host`, however, has its own **autoscan**: when given `vendorid`/`productid`
  (optionally `hostport`) and *no* `hostdevice`, it polls every 2 s, opens a matching
  device when it appears and closes it when it disappears (`hw/usb/host-libusb.c`,
  `usb_host_auto_check`). That is exactly the re-enumeration follow we need, so the fix is
  to make libvirt hand QEMU those properties instead of `hostdevice`.

### 5.3 The fix (2026-10-06): QEMU `usb-host` autoscan via `<qemu:override>`

`scripts/pctv-win7-autoscan.sh` (idempotent; run `sudo ./scripts/pctv-win7-autoscan.sh`)
rewrites the persistent `win7` domain XML so QEMU gets:

- `hostdevice` **removed** (`<qemu:property name='hostdevice' type='remove'/>`)
- `vendorid=8964` (`0x2304`) / `productid=558` (`0x022e`) / `hostport='3'` → autoscan
- `<source guestReset='off'>` → `guest-reset=false`, so guest port resets no longer reset
  the physical card

Generated QEMU arg (present in `/var/log/libvirt/qemu/win7.log`):

```
-device '{"driver":"usb-host","id":"hostdev0","guest-reset":false,"bus":"usb.0",
          "port":"4","vendorid":8964,"productid":558,"hostport":"3"}'
```

`machines/macbook-pro-2009/pctv-usb.nix` (the old udev detach/attach helper) was **deleted**:
it forced a `virsh detach-device`/`attach-device` on every re-enumeration, which reset the
card and could not keep up anyway. Autoscan replaces it. `boot.blacklistedKernelModules =
[ "dvb_usb_dib0700" ]` stays in `machines/macbook-pro-2009/default.nix` so the host driver
cannot grab the card during autoscan gaps.

Verified 2026-10-06 by unbinding/rebinding the EHCI controller (`0000:00:06.1`) while the VM
ran: the card came back with a new device number and QEMU re-claimed it (sysfs driver back
to `usbfs`) within ~4 s, with no udev involvement.

**Guest driver (resolved 2026-10-06).** The earlier "Code 10 / warning triangle" state was
a *ghost* device instance (`USB\VID_2304&PID_022E\5&2C96EA2E&0&4`, port-keyed — not the
serial-keyed `\0000000100` that the driver actually binds) left over from the old
detach/attach churn. After a clean Windows boot on the autoscan transport the ghost is gone
and **every `VID_2304` PnP node reports `ERR=0`** (PCTV 320cx, IR receiver, HID functions).
The `Ltn_hyd7700pc_64` driver service is RUNNING and DirectShow enumerates the capture
sources. See **§5.4** for the full guest-side analysis and the remaining blocker.

### 5.4 Guest-side capture analysis + resume brief (2026-10-06)

**Transport is fixed and the driver is healthy. The only thing between us and a captured
frame is selecting the S-Video input on the driver's crossbar property page (§5.4.5).**

**Guest SSH in one line:**
`./scripts/pctv-win7-ssh.sh '<command>'` — equivalent to
`ssh -i ~/.ssh/pctv_win7_ed25519 Chris@192.168.122.59`. See **§5.4.1** for the full
connection details (user, key, ACL, password, IP discovery, scp).

#### 5.4.1 Guest access (already set up)

**Connection details**

| | |
| --- | --- |
| Host (IP) | **`192.168.122.59`** — libvirt `default` network on `virbr0`; DHCP lease, hostname `Chris-PC`, MAC `52:54:00:58:df:b4` |
| User | **`Chris`** (shown as `chris-pc\chris`), member of `BUILTIN\Administrators` |
| Auth | key **`~/.ssh/pctv_win7_ed25519`** (host) → `C:\ProgramData\ssh\administrators_authorized_keys` (guest) |
| Password | **`password`** (fallback auth; see `--password` below) |
| Elevation | the SSH session is **already elevated** — `net session` and `fltmc` both succeed, so no `runas` is needed |
| Guest OS | Windows 7 x64, plain `cmd.exe` shell, **PowerShell 2.0** |

**Preferred: the wrapper script** (resolves the IP from the DHCP lease, makes sure the
libvirt `default` net is up, applies the right ssh/scp options):

```sh
./scripts/pctv-win7-ssh.sh 'whoami'                            # run a command
./scripts/pctv-win7-ssh.sh                                     # interactive cmd.exe
./scripts/pctv-win7-ssh.sh --start                             # boot the VM first if needed
./scripts/pctv-win7-ssh.sh --password 'whoami'                 # password auth fallback
./scripts/pctv-win7-ssh.sh --get 'C:/Users/Chris/frame.raw' /tmp/frame.raw
./scripts/pctv-win7-ssh.sh --put /tmp/tool.cs 'C:/Users/Chris/tool.cs'
```

**Raw equivalents** (if the wrapper isn't to hand):

```sh
# ssh
ssh -i ~/.ssh/pctv_win7_ed25519 \
    -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 \
    Chris@192.168.122.59

# scp (guest paths use forward slashes inside single quotes)
scp -i ~/.ssh/pctv_win7_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    Chris@192.168.122.59:'C:/Users/Chris/frame.raw' /tmp/frame.raw
```

Notes:

- Rediscover the IP if the lease changes:
  `virsh --connect qemu:///system net-dhcp-leases default`.
- `virsh` works **without `sudo`** (the user is in the `libvirtd` group).
- The key is authorized in `C:\ProgramData\ssh\administrators_authorized_keys` with ACL
  `SYSTEM:F` + `Administrators:F`. That ACL is required: the guest's `sshd_config` has a
  `Match Group administrators` block pointing there, and **sshd ignores the file if the ACL
  is wrong**. To revoke access, delete the `ssh-ed25519 … pctv-win7` line.
- There is **no `sshpass`/`expect`** on this host; the `--password` mode works via
  `SSH_ASKPASS`. `PCTV_WIN7_PASSWORD` overrides the default.
- Prerequisites: the libvirt `default` network must be active and the `win7` domain running:

  ```sh
  virsh --connect qemu:///system net-start default    # autostart is set now
  virsh --connect qemu:///system start win7           # or: ./scripts/pctv-win7-ssh.sh --start
  ```

  A host reboot left the network down once (before autostart was set).
- **The guest is PowerShell 2.0.** `powershell -Command -` (stdin script) silently produces
  nothing; use `-EncodedCommand` (UTF-16LE + base64) for anything non-trivial.

Helper binaries were built **on the guest** with
`C:\Windows\Microsoft.NET\Framework64\v3.5\csc.exe` and live in `C:\Users\Chris\` (with
`.cs` sources alongside):

| tool | purpose |
| --- | --- |
| `dsenum.exe` | list DirectShow video/audio capture devices |
| `dstree.exe` | dump each PCTV filter's pins + connection state |
| `dsiid.exe` | QI each PCTV filter/pin for IAMCrossbar, IKsControl, IBDA_*, IAMTVTuner, … |
| `dsprobe.exe` | decoder TV-format + crossbar enumeration |
| `dsroute.exe` | attempt crossbar routing via IKsControl (fails — §5.4.4) |
| `dsbda.exe` | QI IBDA_Topology + list property-page CLSIDs |
| `dscap.exe` | build xbar→capture→SampleGrabber→NullRenderer graph, grab a frame |
| `xbarui.exe` | show the crossbar filter's property page (`OleCreatePropertyFrame`) |
| `xbarui_c.exe` | console build, used to print the property-page CLSIDs |

#### 5.4.2 What works

- Transport: QEMU `usb-host` autoscan follows re-enumerations. Re-verified after a host
  watchdog reboot (card moved `devnum` 3→5, still `usbfs`, guest unaffected).
- Guest PnP: **all `VID_2304` nodes `ERR=0`**; the old Code 10 ghost instance is gone.
- DirectShow enumeration (`dsenum.exe`):
  - Video input: **`PCTV DiB BDA Analog Capture`**
  - Audio input: **`PCTV DiB BDA Analog Audio Capture`**, `Line In (High Definition Audio)`
- Filter topology (`dstree.exe`) — `PCTV DiB BDA Analog Xbar`:
  - inputs: `0: Video Tuner In`, **`1: Video SVideo In`**, `2: Video Composite In`,
    `3: Audio Tuner In`, `4: Audio Line In`
  - outputs: `0: Video Decoder Out`, `1: Audio Decoder Out`
  - `PCTV DiB BDA Analog Capture` pins: `Analog Video In`, `Analog Audio In`, `Capture`
- `dscap.exe` builds the graph: crossbar `Video Decoder Out` → capture `Analog Video In`,
  then capture `Capture` → SampleGrabber → NullRenderer. Negotiates **YUY2 720×576 16 bpp**.
- Decoder (`IAMAnalogVideoDecoder`): `AvailableTVFormats=0x1ffff7`; current **`0x10` =
  PAL_B** (so NTSC_M `0x1`, PAL_I `0x100`, SECAM_B `0x1000` are all available).

#### 5.4.3 The blocker: analog input is not routed

`dscap.exe` → `IMediaControl::Run()` returns **`0x8007048F`**
(`HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED)`); the SampleGrabber reports `0x80040227`
(`VFW_E_NOT_CONNECTED`) and no frame is produced.

Cause: the crossbar is pinned to **`0: Video Tuner In`**, so the S-Video source never
reaches the decoder and the capture filter reports "device not connected". The property page
confirms *Current Input: `0: Video Tuner In`*.

**VirtualDub cannot work for this device.** It drives a DirectShow graph containing only
the BDA capture filter; it never instantiates the crossbar filter nor connects
`Video Decoder Out` → `Analog Video In`. So the input stays unrouted no matter what the
`Video → Source` dialog shows. (This also explains the empty preview.)

#### 5.4.4 What the driver does *not* expose (all tried, all negative)

| API | IID / property set | result |
| --- | --- | --- |
| `IAMCrossbar` | `C6E13370-30AC-11d0-A18C-00A0C9118956` | QI fails on all PCTV filters |
| `IKsControl` | `28F54685-06FD-11D2-B27A-00A0C9223196` | QI fails on the xbar filter **and** its pins |
| `IKsPropertySet` + crossbar set | `6E8D4A20-310C-11D0-B79A-00AA003767A7` | `IKsPropertySet` present, but `QuerySupported` → `0x0`; `Set` → `0x80070492` `ERROR_NOT_SUPPORTED` |
| `IBDA_Topology` | `79B56888-7FEA-4690-B45D-38FD3C7849BE` | QI fails on all PCTV filters |
| `IBDA_DeviceControl` | `FD0A5AF3-B41D-11d2-9C95-00C04F7971E0` | not exposed |

The **only** control surface is the crossbar filter's property page. `OleCreatePropertyFrame`
on `PCTV DiB BDA Analog Xbar` yields exactly one page, CLSID
**`{71f96461-78f3-11d0-a18c-00a0c9118956}`**, titled *"PCTV DiB BDA Analog Xbar
Properties"*, with a **Crossbar** tab showing:

- **Input** (dropdown) — currently `0: Video Tuner In`; options include
  `1: Video SVideo In`, `2: Video Composite In`
- *Current Input*, *Related Pin*, *Output*, *Related Pin*, *Link Related Streams*
- OK / Cancel / Apply

The input route can therefore only be set through that dialog (which internally calls the
`IAMCrossbar` the driver keeps to itself).

#### 5.4.5 Next steps (resume here)

> ⚠️ **Superseded by §5.5 (2026-10-06 evening).** These steps were followed; the route is
> now set programmatically, and the capture still fails. Read §5.5 before repeating any of
> this. Repeating capture attempts on the live VM is known to bugcheck the guest.

1. **Select the input.** `xbarui.exe` was launched on the console session (via
   `schtasks /create /tn xbarui /tr … /sc once /st 00:00 /ru Chris /rp password /it /f` then
   `schtasks /run /tn xbarui`). The dialog was **closed again before this session ended**, so
   it must be re-launched; the `xbarui` scheduled task persists, so just run:

   ```sh
   ./scripts/pctv-win7-ssh.sh 'schtasks /run /tn xbarui'
   ```

   Then set **Input → `1: Video SVideo In`** and click **OK**.
   ⚠️ Programmatic clicking was unreliable because Windows Task Manager kept stealing
   focus — the user can simply click it on the console.
   ⚠️ `xbarui.exe` is a **winexe**, so over plain ssh it produces no output and blocks; if it
   ever hangs an ssh session, kill it with `taskkill /im xbarui.exe /f` (the console build
   `xbarui_c.exe` is the one that prints the page CLSID).

2. **Grab a frame** (`0 1` = route OUT0 `Video Decoder Out` ← IN1 `Video SVideo In`; use
   `0 2` for composite):

   ```sh
   ./scripts/pctv-win7-ssh.sh 'C:\Users\Chris\dscap.exe 0 1 C:\Users\Chris\frame.raw'
   ./scripts/pctv-win7-ssh.sh --get 'C:/Users/Chris/frame.raw' /tmp/frame.raw
   ffmpeg -f rawvideo -pix_fmt uyvy422 -s 720x576 -i /tmp/frame.raw -frames:v 1 /tmp/frame.png
   ```

3. **If the picture is torn / wrong standard**, set the TV format via
   `IAMAnalogVideoDecoder`: `put_TVFormat` with `0x1` NTSC_M, `0x10` PAL_B (current),
   `0x100` PAL_I, `0x1000` SECAM_B.
4. **If the property-page route doesn't persist** (or resets on re-enumeration), use a
   BDA-aware app rather than fighting it:
   - **Windows Media Center** — *already installed* (`C:\Windows\ehome\ehshell.exe`); this is
     the BDA analog model the driver was written for.
   - **NextPVR / MediaPortal / DVBViewer** — support BDA analog + input selection.
5. **Longer term** the §6 route is still the only way to capture on Linux; the usbmon trace
   (§6.2) is best taken *while the input route is set*, since that is when the interesting
   control transfers occur.

#### 5.4.6 Gotchas hit while building the guest tools (saves the next session time)

- **.NET 3.5 only** on the guest: no `IntPtr.Add` — use `new IntPtr(p.ToInt64() + off)`.
- `IMoniker.BindToObject` marshals as `void` in .NET (there is no HRESULT to check).
- `IMediaControl` is an **IDispatch** interface: the interop declaration needs the 4
  IDispatch vtable slots before `Run`/`Pause`/`Stop`/`GetState`, or `Run()` returns
  `E_POINTER` with a nonsense HRESULT (`0x8007048f` came from a *correct* declaration —
  the earlier wrong-declaration variant returned `0x80004003`).
- `IGraphBuilder` vtable order: `AddFilter, RemoveFilter, EnumFilters, FindFilterByName,
  ConnectDirect, Reconnect, Disconnect, SetDefaultSyncSource, Connect`.
- `CAUUID.pElems` is a pointer to an array of **GUIDs** — read with
  `Marshal.PtrToStructure(new IntPtr(pElems.ToInt64() + i*16), typeof(Guid))`, not
  `ReadIntPtr`.
- QEMU 10.2 `input-send-event` absolute-pointer events take **one axis per event**:
  `{"type":"abs","data":{"axis":"x","value":N}}` (a combined `x`/`y` payload is rejected).
- `{71F9646x-78F3-11d0-A18C-00A0C9118956}` is the KS/WDM AVStream property-page family;
  `{71f96461-…}` in particular is the analog-crossbar page.
- The host's hard lockup that interrupted this work was the NVIDIA TCO watchdog
  (`nv_tco: Watchdog reboot detected`), not the VM — the reference to it is only relevant
  because the reboot cleared the runtime udev mask and stopped the libvirt `default` net.

### 5.5 Session 2026-10-06 (evening): page automated, capture still dead, driver bugchecks

#### 5.5.1 Verdict

The analog capture **does not work** with this driver in this VM, and the failure is *not*
input routing. Three independent facts, each verified:

1. **The route is programmable** — the §5.4 "must be done by hand" blocker is solved (§5.5.2).
2. **The capture still never streams.** `IMediaControl::Run()` fails (`0x8007048F` /
   `0x8007001F`) and a usbmon trace during a full attempt shows the driver issuing
   **1060 bulk-OUT + 61 control transfers and ZERO bulk-IN** (§5.5.4). It uploads firmware
   and configures, then never starts a stream.
3. **The driver bugchecks the kernel** — `0x0000000A` `IRQL_NOT_LESS_OR_EQUAL`, which is
   what produced the Windows Error Recovery boot loops (§5.5.6).

A GUI capture program cannot "work" on top of this. Either the driver's analog path is
broken under QEMU's `usb-host` passthrough, or it is simply broken for this card.

#### 5.5.2 The property page *is* programmable (new)

The crossbar page CLSID is `{71f96461-78f3-11d0-a18c-00a0c9118956}` (`ksxbar.ax`).

**`CoCreateInstance` on it is a trap.** It returns `S_OK`, but the object answers
`E_NOINTERFACE` (`0x80004002`) for *every* useful interface — `IPropertyPage`,
`IPropertyPage2`, `IOleObject`, `IPersist`, `ISpecifyPropertyPages` — in **both** the
32-bit and 64-bit hosts. It is only initialised by the property-frame protocol:

```csharp
OleCreatePropertyFrame(IntPtr.Zero, x, y, caption, 1, ppUnk, 0, IntPtr.Zero, 0, 0, IntPtr.Zero);
```

Run that on the `PCTV DiB BDA Analog Xbar` filter (on an STA thread), and a working page
appears as a top-level `#32770` dialog titled `caption`.

Window tree (found by `EnumWindows`/`EnumChildWindows` + `GetDlgCtrlID`):

```
#32770  (frame dialog, title = caption)
└─ #32770 (page container)
   ├─ ComboBox id=1002   <- Input            (items below, cur=0)
   └─ Edit     id=1001   <- read-only display of the current input
```

Input combo items: `0: Video Tuner In`, `1: Video SVideo In`, `2: Video Composite In`.

**The commit path (this is the part that wasted the most time):**

```csharp
SendMessage(combo, CB_SETCURSEL, (IntPtr)idx, IntPtr.Zero);
// The CBN_SELCHANGE notification MUST go to the combo's IMMEDIATE PARENT dialog,
// NOT to the frame (and not to the combo's grandparent).
SendMessage(GetParent(combo), WM_COMMAND,
            (IntPtr)((CBN_SELCHANGE << 16) | (GetDlgCtrlID(combo) & 0xffff)), combo);
// only now does the page mark itself dirty and ENABLE the Apply button
SendMessage(applyButton, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
SendMessage(okButton, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
```

Sending `WM_COMMAND` to the frame leaves the page clean and Apply disabled — the route is
silently not committed. Sending it to the combo's parent enables Apply, and after
Apply/OK the page's own model updates: re-opening the page **on the same filter instance**
reports *Current Input: `2: Video Composite In`* and *Related Pin: `4: Audio Line In`*.

This is implemented in `scripts/pctv-tools/pctvroute.cs`:

```sh
C:\Users\Chris\pctvroute.exe svideo      # or composite | tuner | read | test
```

#### 5.5.3 The route is per-filter-instance and never reaches the device

For all the page's apparent success, the setting does **not** persist or propagate:

- Bind the crossbar twice in the same process, route instance **A**, then open the page
  **on a fresh instance B** (even in the same process) → B still reports
  `0: Video Tuner In`. Releasing A does not change B.
- No USB traffic and no relevant registry write is observed while the page's Apply runs.

So the route lives in the DirectShow/KS filter object's own state. Driving the page on a
*separate* instance (e.g. a human clicking `xbarui.exe` on the console) cannot possibly
route the graph a capture app later builds — which is why the §5.4.5 plan never worked.

#### 5.5.4 The capture never streams (USB evidence)

Graph built and connected successfully every time — `AddFilter` and all `Connect` calls
return `S_OK` (crossbar `0: Video Decoder Out` → capture `Analog Video In`, plus optional
`tuner Analog Video → xbar 0: Video Tuner In`, plus optional audio through the crossbar and
to a second NullRenderer). Then:

| Attempt | Result |
| --- | --- |
| `IMediaControl::Run()` (xbar → capture) | `0x8007048F` `ERROR_DEVICE_NOT_CONNECTED` |
| `IMediaControl::Run()` (tuner + xbar + capture) | `0x8007001F` `ERROR_GEN_FAILURE` |
| `IBaseFilter::Run(0)` on the capture filter directly | same failures — the capture filter itself cannot start |
| retry `Run` up to 5× on the same instances after re-settling | still fails |
| `ICaptureGraphBuilder2::SetOutputFileName` (AVI) | `0x80040154` `REGDB_E_CLASSNOTREG` — the AVI Mux is not registered in this guest |
| `ICaptureGraphBuilder2::RenderStream` (PREVIEW and CAPTURE) | `0x8004025F` |

**usbmon during a full attempt** (`/sys/kernel/debug/usb/usbmon/2u` on the host):

```
S Bo: 1060   (bulk OUT  - firmware/config)
S Co/S Ci: 61 (control  - power/mode)
S Bi:    0   (bulk IN   - THE STREAM)      <-- nothing, ever
+ no isochronous URBs either
```

The device also **re-enumerated mid-attempt** (devnum `5` → `6`, same VID/PID). On warm
retries afterwards there was *no* traffic at all. So the driver loads firmware, configures,
and the capture filter's start path fails without ever submitting a read URB.

Device interfaces the driver actually registers (from `DeviceClasses`, all on the single
USB node `VID_2304&PID_022E`):

```
{65E8773D-...}  video capture      {A799A800-...} TV tuner    {A799A801-...} crossbar
{A799A802-...}  TV audio           {33D9A762-...} audio in/out {6994AD05-...}
{71985F48-...}  {CC7BFB46-...}     {FD0A5AF4-...} BDA receiver {A5DCCBF10-...} USB
+ HID {4D1E55B2-...}, {884B96C3-...}
```

There is **no interface for the `ControlFilterName`** ("PCTV DiB Control Filter") the INF
defines — nothing to switch the hybrid between DVB-T and analog modes.

#### 5.5.5 Everything that did not work

All of the following were tried and returned negative. This is the exhaustive list; do not
re-spend time on them without new information.

**Routing / control interfaces**

| Attempt | Result |
| --- | --- |
| `IAMCrossbar` (`C6E13370-30AC-11d0-A18C-00A0C9118956`) on every PCTV filter and pin | `E_NOINTERFACE` (`0x80004002`) |
| … same, **after** adding the filters to a graph and connecting them | still `E_NOINTERFACE` — it does not appear later |
| `IKsControl` (`28F54685-...`) on filter and pins | not exposed |
| `IKsPropertySet` (`31EFAC30-...`) + KS crossbar set `6E8D4A20-310C-11D0-B79A-00AA003767A7` | `QuerySupported` → nothing supported; property access → `0x80070492` `ERROR_NOT_SUPPORTED` |
| `IBDA_Topology`, `IBDA_DeviceControl` | not exposed |
| KS crossbar property set on the **capture** filter/pins | `0x80070492` / `0x80070006` (`ERROR_INVALID_HANDLE`) |
| `IAMTVTuner` tuner-input methods (`put_ConnectInput`, `put_InputType`) | stubs — see below |
| All Windows registered DirectShow filter categories (122 filters) for a PCTV control filter | no PCTV software filters at all |
| `DeviceClasses` scan for a Control Filter interface | none registered |

**The tuner's `IAMTVTuner`** — the one genuinely new surface found. The tuner filter *does*
answer `QueryInterface` for `IAMTVTuner`, but with a **non-standard IID and no `IAMTuner`
base**:

```
IID actually answered:  211A8766-03AC-11D1-8D13-00AA00BD8339   (note ...BD8339, not ...BDCDFD)
IAMTuner base interface: not exposed (QI fails -> InvalidCastException on inherited methods)
```

A raw vtable scan (`vtprobe.cs` / `pc2.cs`) showed the layout is shifted relative to the
SDK, and the parts that exist work while the input select does not:

- `get_AvailableTVFormats` → `0x1FFFF7`; `get_TVFormat` → `0x10` (PAL_B)
- `GetNumInputConnections` → `3`
- `get_ConnectInput` → `E_INVALIDARG` (`0x80070057`) — a stub, though raw vtable slot 22
  returns `1` and cannot be changed
- every candidate `put_*` slot (`put_ConnectInput` / `put_InputType`) → `E_NOTIMPL`
  (`0x80004001`) or `E_INVALIDARG` — all stubs

**Graph / capture topologies** (all built and connected cleanly, none started)

- capture-only (no crossbar, no tuner)
- crossbar → capture
- tuner + crossbar → capture
- … plus crossbar audio → capture audio, and capture audio → a second NullRenderer
- capture → SampleGrabber → NullRenderer (negotiated YUY2 720×576)
- capture → NullRenderer direct
- `ICaptureGraphBuilder2::RenderStream` for PREVIEW and CAPTURE
- `put_TVFormat` set to PAL_B before `Run`
- retries after the device re-enumerated / after a host-side device cold reset

**Other dead ends**

- `IAMAnalogVideoDecoder` **works** (`get/put_TVFormat`, `AvailableTVFormats`) — the capture
  filter's management interface answers, only its data path does not.
- Host-side "cold reset" of the card (unbind/rebind the EHCI PCI controller
  `0000:00:06.1`) did not help; it also tended to leave the device **unclaimed by QEMU**
  (no `usbfs` driver), so the guest lost it until a clean VM restart.
- **VirtualDub** (per §5.4.3) does not build the crossbar at all.
- Windows Media Center was **not** tried — it is interactive and would risk another crash.

#### 5.5.6 The driver bugchecks the kernel (root cause of the boot loops)

The guest repeatedly fell into Windows Error Recovery. That was not a boot-config problem:
the event log shows a **kernel bugcheck**, twice:

```
BugCheck 0x0000000A  IRQL_NOT_LESS_OR_EQUAL
  p1 = 0x0000000004944100   (bad address accessed)
  p2 = 0x0000000000000002   (IRQL 2)
  p3 = 0x0000000000000001   (read)
  p4 = 0xfffff8000288ca0a   (faulting instruction)

BugCheck 0x0000000A
  p1 = 0x0000000004927740  p4 = 0xfffff800028a3a0a
```

A kernel access violation at IRQL 2 = a **driver** fault. The PCTV kernel service
`Ltn_hyd7700pc_64` is `RUNNING`, and the crashes line up exactly with device/capture
activity. Two things then turned a crash into a visible **infinite loop**:

1. **The QEMU watchdog.** The domain had
   `<watchdog model='itco' action='reset'/>`. At the Error Recovery screen the guest is not
   petting the watchdog, so QEMU **hard-reset the VM every ~30 s**. This is why it appeared
   to boot-loop rather than sit on the menu.
2. **Windows auto-restart.** `HKLM\SYSTEM\CurrentControlSet\Control\CrashControl\AutoReboot`
   defaults to `1`, so each BSOD rebooted straight back into the failure.

Fixes applied (persistent):

```sh
# watchdog -> no reset (libvirt)
virsh dumpxml win7 > /tmp/win7.xml
sed -i "s|action='reset'|action='none'|" /tmp/win7.xml
virsh define /tmp/win7.xml
```

```bat
:: show the BSOD instead of looping
reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v AutoReboot /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v CrashDumpEnabled /t REG_DWORD /d 7 /f
```

With both in place the guest boots normally and stays up. Any future crash now leaves a
readable BSOD / `C:\Windows\MEMORY.DMP`.

**Trigger and live-VM hazard.** The first "did not shut down successfully" flag came from a
`virsh destroy` (hard power-off) used to clear a stuck USB device — a clean guest shutdown
(`shutdown /s /t 0` over ssh) should have been used instead. Separately, **repeated analog
capture attempts make the card drop out of the guest** (the host still sees `VID_2304&PID_022E`
on `usbfs`, but Windows sees no `VID_2304` PnP node at all); it only comes back after a
clean guest reboot. Treat capture attempts on the live VM as crash-risky.

#### 5.5.7 Guest convenience changes made

Windows 7 auto-login (so the VM reaches the desktop unattended):

```bat
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon  /t REG_SZ /d 1 /f
reg add "...\Winlogon" /v DefaultUserName /t REG_SZ /d Chris /f
reg add "...\Winlogon" /v DefaultDomainName /t REG_SZ /d CHRIS-PC /f
reg add "...\Winlogon" /v DefaultPassword /t REG_SZ /d password /f
reg add "...\Winlogon" /v DisableCAD /t REG_DWORD /d 1 /f
reg add "...\Winlogon" /v ForceAutoLogon /t REG_SZ /d 1 /f
```

Verified: the next boot went straight to the desktop with no password prompt.

#### 5.5.8 Methodology gotchas (cost real time this session)

- **`qemu-img check` on a live image is worthless.** `qemu-img check -U <img>` against a
  running VM reported **9960** errors (`ERROR OFLAG_COPIED data cluster … refcount=0`).
  With the VM stopped the same image reports **"No errors were found".** The "corruption"
  was mid-write refcount metadata. Never diagnose image corruption on a live VM, and never
  run `qemu-img check -r all` against one.
- **The driver `.sys` files are packed.** `Ltn_hyd7700pc_64.sys` yields essentially no
  ASCII/UTF-16 strings (2 short ASCII runs). The INF (`PCTV.inf`) is the usable source of
  filter names and registry values, not the binary.
- **The zip's `.sys` files do not match its INF's driver names.** `PCTV.inf`
  (`[SourceDisksFiles]`) references `Ltn_stk7070P*.sys` / `Ltn_hyd7700pc*.sys`; the analog
  filter names only appear in the INF. The installed `C:\Windows\INF\oem3.inf` is this same
  INF. Installed driver version is already the latest (Liteon 3.0.3.3, "AVSTREAM/BDA driver").
- **usbmon buffering.** A backgrounded `timeout cat /sys/kernel/debug/usb/usbmon/2u` can
  yield 0 lines from buffering — use `sudo stdbuf -o0 …`. And never `pkill -f usbmon/2u`
  from the same shell: it self-matches and kills the session (this aborted a command here).
- **`virsh screenshot win7 /tmp/x.ppm`** is the fastest way to see what the guest console is
  actually showing (it writes PNG despite the `.ppm` name). Invaluable for "it keeps
  rebooting" debugging.
- **`virsh send-key`** can drive the Error Recovery menu (`KEY_UP`×2 + `KEY_ENTER` selects
  *Safe Mode with Networking*).

#### 5.5.9 Tools

Sources for every tool used are preserved in **`scripts/pctv-tools/`** (they previously
existed only inside the guest as `C:\Users\Chris\*.exe`/`*.cs`). See that directory's
`README.md` for the full table and the build command. Most useful:

- `pctvcom.cs` — shared COM/DirectShow interop (compile with everything else)
- `pctvroute.cs` — the property-page router (`svideo|composite|tuner|read|test`)
- `pindump.cs` — per-pin media-type dump
- `vtprobe.cs` / `pc2.cs` — raw interface vtable scanner
- `allf.cs` — enumerate every registered DirectShow filter category
- `mincap.cs` — minimal capture attempt + frame poll

#### 5.5.10 Where to go from here

The §5.4.5 plan (route the page, grab a frame) is a dead end — §5.5.2/§5.5.4 explain why.
Realistic options:

1. **Use a different capture device.** A USB composite/S-Video capture dongle captures the
   VCR directly on Linux via `v4l2`/ffmpeg — no Windows VM, no closed driver, no crashes.
   This is by far the most likely to actually work.
2. **Try Windows Media Center** (`C:\Windows\ehome\ehshell.exe`, installed) once, on the
   console, purely as a *test* of whether the vendor's intended analog path can start at
   all. If WMC cannot capture either, the driver/hardware is confirmed dead and option 1 is
   the only answer. Expect a possible bugcheck.
3. **Reverse-engineer the driver** (§6) — even more clearly required now, since the
   user-space route is exhausted and the failure is in the kernel driver's start path.
   De-risk with the §6.2 usbmon trace of the **digital** path first.

### 5.6 Session 2026-10-06 (late): the *other* Pinnacle drivers — installed, and both are worse

Goal: the stock 2007 driver (`Ltn_hyd7700pc_64.sys`) is the only one that builds the analog
KS stack, and its crossbar is broken (§5.4.3, §5.5.3). Try the **other** drivers in the
vendor packages on the same device and see whether a different binary initialises the
composite/S-Video path correctly.

#### 5.6.1 Where the other drivers are

`Pinnacle_TVCenterProSetup_5.4.0.3032.exe` (264 MB, in the repo root) is **not** Inno Setup —
it is a PE with a WinRAR SFX resource whose payload is a **RAR archive** in the `Rar!` stream
(`7z`/`innoextract` cannot open it; `unrar x "[0]"` can — `NIXPKGS_ALLOW_UNFREE=1 nix shell
--impure nixpkgs#unrar`). Inside: `Driver/` = 170 files, 15 INFs, one folder per model line.

Grepping every INF for the device's hardware id: **only `Driver/PCTV 72e/PCTV.inf` claims
`USB\VID_2304&PID_022E`** (the 320cx). Three other packages are DiB0700-bridge hybrids that
register the same analog BDA filter names (`AnlgXBarFilterName`, `AnlgCaptureFilterName`, …)
and contain Conexant **cx2584x** video-decoder code — i.e. the same analog front-end family:

| driver | version | date | x64 | embedded Authenticode | analog code | result on the 320cx |
| --- | --- | --- | --- | --- | --- | --- |
| `Ltn_hyd7700pc_64.sys` (PCTV 72e, installed) | 1.0.0.0 | 2007-10-19 | yes | none (WHQL catalog `ltn_pctv_64.cat`) | yes | KS stack **created**, crossbar broken |
| `mod7700.sys` (`Driver/PCTV 200Xe/64 bit`, PCTV 2000e/2001e/280e/73e/73e Solo) | 3.12.4.0 | 2008-06-19 | yes | **valid** (Microsoft Code Verification Root) | yes | loads, **only** `PCTV DiB Control Filter`, no capture stack |
| `dvb7700all.sys` (`Driver/PCTV 340e 801e/64 bit`) | 2.3.3.28 | 2008-06-12 | yes | **none** | yes | blocked by CI until test-signed; then **no PCTV filters at all** |

(PE certificate-directory parse in `pctv-linux/driver2/` — data directory index 4 at
`OptionalHeader+96` for PE32 / `+112` for PE32+; getting that offset wrong reports every
driver as "signed".)

#### 5.6.2 How to install a *modified* INF on Win7 x64 (the mechanics, all logged)

Both experiments need an INF edited to add `USB\VID_2304&PID_022E`, which invalidates the
package catalog. What it takes:

1. `UpdateDriverForPlugAndPlayDevices` lives in **`newdev.dll`** and only the **W** entry
   point is exported (`setupapi.dll` → `EntryPointNotFoundException`). Wrapper:
   `scripts/pctv-tools/drvinstall.cs`.
2. It must run **in the interactive session**. From ssh it is non-interactive and SetupAPI
   refuses to show the prompt:
   `!!! sto: Driver package does not contain a catalog file. No error message will be
   displayed as client is running in non-interactive mode.` → `0xE000023F`, staging fails.
   `pnputil -i -a` fails outright (`A file could not be verified because it does not have an
   associated catalog signed via Authenticode`) even with
   `HKLM\SOFTWARE\Microsoft\Driver Signing\Policy = 00` and `nointegritychecks on`.
3. Run it as a **scheduled task in the logged-on session with highest privileges**
   (`schtasks /create /tn pctvinst /tr C:\pctv5\inst4.bat /sc once /st 23:59
   /ru "Chris-PC\Chris" /rl HIGHEST` — without `/rl HIGHEST` the call returns `0x5`).
   The task launches `scripts/pctv-tools/instclick.cs`, which calls the installer on a
   background thread and `EnumWindows`/`BM_CLICK`s the **"Windows Security → Install this
   driver software anyway"** radio + OK (class `#32770`). Clicking OK *without* the radio
   gives `Do&n't install this driver software` → still `0xE000023F`.
4. A reinstall with an **unchanged `DriverVer` does not re-copy the `.sys`** — bump the
   version (and/or use a new INF file name) when iterating on a binary.
5. `Win32_PnPEntity::Disable/Enable` do not exist on Win7/PS 2.0 (`pnpreset.ps1` is there but
   needs `SetupDiCallClassInstaller(DIF_PROPERTYCHANGE)` to work).

#### 5.6.3 Driver A — `mod7700.sys` 3.12.4.0 (signed, installs cleanly)

INF: `pctv-linux/driver2/PCTV320cx-mod7700.inf` (200Xe INF + a `MOD7000_320cx.*` section whose
Device Parameters are copied verbatim from the 320cx sections of the stock `PCTV.inf`,
**no `GpioStateTable`** — that table is the 73e/280e board's and could hold the demod in reset).

```
UpdateDriverForPlugAndPlayDevices -> True
NAME: Pinnacle PCTV 320cx (mod7700 test)   Status: OK   ConfigManagerErrorCode: 0
sc query mod7700  ->  STATE 4 RUNNING          (survives a reboot)
allf.exe  ->  [Device Control Filters] PCTV DiB Control Filter      (only)
dsenum  ->  Video Input Devices: (none) / Audio Input Devices: (none)
dstree  ->  (no output)
```

USB side (usbmon, `logs/drv2.parsed`): the driver opens the bridge exactly like the 2007 one —
`c4 02 01a1` (1 B), `44 0f` (3 B ×2), `c4 15` (16 B), then reads the 128-byte ID block
`c4 02 01a0` in 8-byte chunks (`d0 04 23 2e 02 00 01 05` = dib0700 + VID 0x2304 + PID 0x022E).
**No bulk OUT (ep 02) traffic at all** — same as the 2007 driver at idle, so no I2C analog
routing is attempted.

Verdict: the 2008 DiBcom driver binds, starts, talks to the bridge — and **never creates the
analog KS filter factories** (capture/tuner/xbar/audio). Only the control filter.

#### 5.6.4 Driver B — `dvb7700all.sys` 2.3.3.28 (unsigned → CI, then test-signing)

INF: `pctv-linux/driver2/PCTV320cx-dvb7700all{,-ts,-ts2}.inf` (service renamed `mod7700all` and
`DisplayName` changed, otherwise `Error 1078: The name is already in use as either a service
name or a service display name` — both Pinnacle packages use the service name `mod7700`).

* First install succeeds (clicked prompt) but the device gets **`ConfigManagerErrorCode 52`**,
  the service stays STOPPED, `sc start` → **`FAILED 577` (ERROR_DRIVER_BLOCKED)**,
  CodeIntegrity **event 3004** "file hash could not be found on the system".
* `bcdedit /set {current} nointegritychecks on` (with or without `testsigning`) does **not**
  help — Win7 x64 ignores it for kernel images; there is no BCD element for the F8
  "Disable driver signature enforcement" option.
* Importing the **original** (WHQL-catalogued) 340e package with `pnputil -i -a` works
  (`oem8.inf`) but does not make the *modified* package load — and no Pinnacle catalog ever
  appears in `C:\Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}\`.
* **Test-signing works, but only with SHA-1.** The guest has 2 hotfixes and **no KB3033929**,
  so kernel CI rejects SHA-256 Authenticode (user-mode `Get-AuthenticodeSignature` still says
  `Valid` — misleading). Recipe that made it load:

  ```sh
  # host, nixpkgs#openssl + nixpkgs#osslsigncode
  openssl req -x509 -newkey rsa:2048 -keyout k3.key -out c3.crt -days 3650 -nodes -sha1 \
    -subj "/C=GB/O=Pinnacle Test/CN=Pinnacle Test SHA1 Cert" \
    -addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning,1.3.6.1.4.1.311.10.3.22"      # MS test EKU
  openssl pkcs12 -export -inkey k3.key -in c3.crt -out p3.p12 -passout pass:testpw
  osslsigncode sign -pkcs12 p3.p12 -pass testpw -h sha1 -in dvb7700all.sys -out signed.sys
  ```
  ```bat
  certutil -addstore -f Root C:\pctv5\c3.der      :: Local Machine Root store
  bcdedit /set {current} testsigning on           :: ciinfo.exe confirms 0x3 = ENABLED|TESTSIGN
  ```
  A `CA:TRUE` cert fails user-mode verification with *"A certificate's basic constraint
  extension has not been observed"* — the signing cert must be `CA:FALSE` and self-signed.

* Result after that: `Status: OK`, `ConfigManagerErrorCode: 0`, `mod7700all` **RUNNING** — and
  `allf.exe` finds **no PCTV/DiBcom filter at all** (not even a control filter), `dsenum` empty.
  Worse than driver A.

#### 5.6.5 Verdict of this session

* The two 2008 DiBcom-era drivers are **not** a better starting point than the 2007 Pinnacle
  build: `mod7700.sys` creates only the control filter, `dvb7700all.sys` creates nothing.
  Only `Ltn_hyd7700pc_64.sys` (2007) builds the capture/tuner/xbar/tvaudio stack — the one
  whose crossbar never reaches the device (§5.5.3).
* So the analog failure is **not** "the wrong driver was installed": every vendor driver that
  supports this PID either omits the analog stack (2008) or builds it and mis-routes it (2007).
  That strengthens §6 (reverse-engineer `dib0700 + cx2584x` over usbmon) and §7 (different
  capture dongle).
* Useful new capability: **arbitrary INF/driver binaries can now be installed on this guest**
  (newdev + interactive task + prompt click + SHA-1 test signing). That makes the "patch a
  `.sys` and see what it sends" experiment in §6.3 practical.

#### 5.6.6 Guest state after this session (undo notes)

* Driver restored to the stock 2007 package (`pnputil -a C:\pctv6\PCTV.inf` + forced reinstall);
  `dsenum` again lists: `PCTV DiB BDA Analog Capture / PCTV DiB BDA Analog Audio Capture`, `dstree` shows the
  5-input crossbar, `pctvroute read` → `CURRENT 0: Video Tuner In`. Verified in
  `pctv-linux/logs/guest-restored-2007drv.txt`.
* Boot config now has `testsigning on` (it was already on before this session) **and**
  `nointegritychecks on` (added here). Undo: `bcdedit /deletevalue {current} nointegritychecks`.
* Two self-signed certs were added to the guest's Local Machine **Root** store
  (`CN=Pinnacle Test Signing Root`, thumbprint `DE779981BB9E639754EE615F4BD4CC62B38B843D`, and
  `CN=Pinnacle Test SHA1 Cert`). Remove with
  `certutil -delete Root <thumbprint>` (list with `certutil -store Root`).
* Driver store now also holds the test packages: `oem5..oem9` (`pnputil -e`); the device is on
  the re-imported stock `PCTV.inf` package. Guest folders used: `C:\pctv2` (mod7700),
  `C:\pctv3`, `C:\pctv4` (original 340e package), `C:\pctv5` (test-signed), `C:\pctv6`
  (original 72e package). Scheduled task `pctvinst` left in place for the next install.
* Test cert/key material: `/tmp/pctv-sign/` on the host (regenerate if gone — `c3.key/c3.crt`,
  `p3.p12`, password `testpw`).

#### 5.6.7 New tooling / logs from this session

| file | what |
| --- | --- |
| `scripts/pctv-win7-logs.sh <label>` | one-call guest log bundle (PnP tree, driver store, service state, Device Parameters, DS enum, pin tree, crossbar page read, System/CodeIntegrity/DeviceSetupManager events, `setupapi.dev.log` tail) + epoch marker for usbmon slicing |
| `scripts/pctv-tools/drvinstall.cs` | `UpdateDriverForPlugAndPlayDevices` (newdev.dll) CLI: `force`/`readonly`/`ni` |
| `scripts/pctv-tools/instclick.cs` | same call from the **interactive** session + auto-click of the Win7 unsigned-driver prompt; logs to `C:\pctv2\instclick.log` |
| `scripts/pctv-tools/devstate.ps1` | `Win32_PnPEntity` + `Win32_PnPSignedDriver` + driver services for a device-id regex |
| `scripts/pctv-tools/ciinfo.cs` | `NtQuerySystemInformation(103)` → CodeIntegrity options (`0x3` = ENABLED\|TESTSIGN) |
| `scripts/pctv-tools/pnpreset.ps1` | disable/enable a node (needs a SetupAPI class-installer call on Win7 — WMI methods absent) |
| `pctv-linux/driver2/` | the three modified INFs + `mod7700.sys`, `dvb7700all.sys`, originals for reference |
| `pctv-linux/logs/guest-{baseline,dvb7700all,restored-2007drv}.txt` | before / after-driver-B / restored bundles |
| `pctv-linux/logs/{raw-,}drv{2,3}.{bin,parsed}` | usbmon bus-2 captures across both installs (`./parse.sh drv2`) |

---

## 6. Reverse-engineering the analog driver (the RE route)

Verdict: **feasible in principle, and this card is an unusually good candidate — but the
central unknown is the analog ADC silicon, which you can de-risk in an afternoon before
writing any kernel code.** Porting a USB WDM/AVStream driver to Linux is not "port the
.sys"; it is *learn the exact USB control tokens the .sys emits, then teach the existing
Linux driver to emit them and expose them as a V4L2 capture device*.

### 6.1 Why this specific card is the *easy* case

- The Linux driver `dvb_usb_dib0700` has **already reverse-engineered DiBcom's host-side
  USB protocol** for this exact device's digital side. Analog almost certainly rides the
  **same dib0700 core, endpoints and command framing** on the wire — composite/S-Video
  selection is likely just *different control transfers on a protocol Linux already
  understands*, not a foreign wire format.
- Composite capture **bypasses the xc3028 RF tuner** entirely (RCA/S-Video is direct ADC
  input), so you avoid fighting the tuner's multi-hundred-KB firmware blob.
- The driver registers the same "hybrid" filter set DiBcom shipped across many OEM hybrid
  cards (Hauppauge/AverMedia/KWorld), giving a large population of sibling drivers to crib
  command bytes from.

So the plumbing is genuinely favorable. The **unknown that decides everything is what chip
performs the analog video ADC** on the board:

- **Known/common ADC** → short, recognizable init tables → port is days-to-weeks.
- **Proprietary DiBcom analog core with opaque init tables** → months-and-maybe-never.

You **cannot tell which by reading the .sys.** Do the cheap experiment in §6.2 first.

### 6.2 The one-afternoon de-risk: usbmon capture of the Windows driver

Run the §5 Win7 VM plan, but **record USB traffic** while Pinnacle's driver initializes and
you select composite input:

1. Host: `sudo modprobe usbmon`, then find the bus number from `lsusb` (device
   `2304:022e`), e.g. bus `2`. Capture while the guest drives the device:
   `sudo tcpdump -i usbmon2 -w trace.pcap` (replace `2`). Stop after selecting composite
   and grabbing a few frames.
2. `tcpdump -i usbmon2` lists usbmon buses (`usbmon1..N`); pick the one for the PCTV's
   physical controller. Analyze with Wireshark (`usbmon`/`usb` dissector).
3. This works even with KVM hostdev passthrough: the device is detached from the host
   driver, but **usbmon still sees every transfer** the guest triggers.

What the trace answers in one sitting:
- **Init-table size/shape.** A few hundred bytes of clean register writes = standard-ish
  ADC → very port-friendly. A large opaque blob replayed each init = proprietary core.
- **Which bulk endpoint carries the video and in what format** → tells you whether it drops
  straight into a V4L2 vb2 queue or needs a decode/filter stage first.
- **Whether tokens resemble the existing `dib0700` command set** — if so you may only need
  to add a few "enable analog/composite/audio" commands to the existing driver.

### 6.3 The actual port, if the trace looks friendly

1. **usbmon trace** → recover composite-init + start-streaming control sequences (ground
   truth).
2. **Ghidra/IDA on `Ltn_hyd7700pc_64.sys`** only where the trace is ambiguous (which
   control value = which crossbar input, field/VSYNC handling).
3. **Port into `drivers/media/usb/dvb-usb/dib0700_devices.c`**: add a
   `dvb_usb_device_properties` variant that also registers a V4L2/vb2 capture node — or a
   sibling driver if it forks too much. Model the analog side on how `em28xx`/`stk1160`/
   `tm6000` expose capture + video-input/audio mixer as V4L2 subdevices (maps 1:1 onto the
   crossbar/tv-audio/audio-capture filters the Windows driver registers).

Relevant observation: the same zip carries `Ltn_stk7070P.sys` (`VID_2304&PID_0236`, the
PCTV 72e). The "STK" family is an **analog-competent chip lineage with an existing open
Linux driver** — worth checking whether the 320cx's analog side shares an ADC lineage with
it before assuming the analog core is wholly unknown.

### 6.4 Effort / ROI framing

- **Best case** (standard ADC, known framing): concentrated days-to-weeks.
- **Worst case** (proprietary core): months for a flaky result — while the §5 VM route
  produces real captures this week **and** simultaneously yields the §6.2 trace that
  decides the RE question.
- Staged commitment: §5 captures are the deliverable regardless → §6.2 answers "standard
  or proprietary" in one sitting → only then start §6.3.

## 7. Alternative (if the VM route is too painful)

- Use a **Linux-supported composite/S-Video USB capture dongle** (em28xx-based "video
  grabber" class), which creates a real `/dev/video*` and captures well under NixOS with
  `ffmpeg`/`v4l-utils`.
- Keep the PCTV 320cx for what Linux does support: **DVB-T** reception/recording.

## 8. Files / references

- Windows driver zip (source of the hybrid confirmation): `PCTV 72e 320cx.zip`
  (unpacked driver contents are `.sys`/`.inf`/`.cat` for PCTV 72e and PCTV 320cx).
- **`Pinnacle_TVCenterProSetup_5.4.0.3032.exe`** (264 MB, repo root) — the full 2008 vendor
  suite; a WinRAR SFX whose payload is a RAR archive (`unrar x "[0]"`). Its `Driver/` tree holds
  every Pinnacle driver package, incl. the two other DiB0700+cx2584x hybrids tried in §5.6.
- Linux DVB driver (DVB-only): `dvb_usb_dib0700`.
- Host config: `machines/macbook-pro-2009/`.
- libvirt autoscan fix (idempotent): `scripts/pctv-win7-autoscan.sh` — see §5.3.
- Guest capture/analysis tools: **sources preserved in `scripts/pctv-tools/`** (see its
  `README.md` for the build command and a table of every tool) — previously they existed
  only as `C:\Users\Chris\*.exe` / `*.cs` inside the `win7` VM (table in §5.4.1). Rebuild
  with the guest's `csc.exe`, no downloads needed.
- Guest access wrapper: `scripts/pctv-win7-ssh.sh`; key `~/.ssh/pctv_win7_ed25519` (host) →
  `C:\ProgramData\ssh\administrators_authorized_keys` (guest).
  `Chris@192.168.122.59`, password `password` — full connection details in §5.4.1.
- **Guest log bundle: `scripts/pctv-win7-logs.sh <label>`** — one call, writes
  `pctv-linux/logs/guest-<label>.txt` (+ an epoch marker line for usbmon slicing). Run it before
  and after any driver change and diff the two (§5.6.7).
- Driver-install tooling (§5.6.2): `scripts/pctv-tools/drvinstall.cs` (newdev CLI) and
  `scripts/pctv-tools/instclick.cs` (install from the interactive session + prompt auto-click);
  SHA-1 test-signing recipe in §5.6.4.
- The driver's analog capture model is the **Windows BDA analog** one; filter names are in
  the device's `Device Parameters` registry key (`AnlgXBarFilterName`, `AnlgCaptureFilterName`,
  `ControlFilterName`, …) — see §5.4.4 for what that model does *not* expose.
- **VM stability knobs** set in 2026-10-06 (see §5.5.6): libvirt watchdog
  `action='none'` (was `reset`, which hard-reset the guest every ~30 s at the
  Windows Error Recovery screen), and guest `CrashControl\AutoReboot=0`.
- **VM auto-login** (`Chris` / `CHRIS-PC`) is enabled — see §5.5.7.
- `win7.qcow2.bak` (7.8 G sparse) in `/var/lib/libvirt/images/` is a safety copy taken
  while chasing the false corruption alarm in §5.5.8; safe to delete.
