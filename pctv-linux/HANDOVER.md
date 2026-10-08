# HANDOVER — pctv320cx native driver, on hardware

> **READ `TRUTH.md` FIRST.** It is the single authority for what is known to be
> true as of 2026-10-08 18:50. This file is a running log and contains claims that
> were later disproved — notably the 2026-10-08 16:20/18:05 entries below, which
> concluded "the card is dead / the self-boot image is gone". **That conclusion is
> wrong** (retracted in `TRUTH.md` §8): the card was revived at 18:31 by the
> in-tree driver's cold-state firmware download and is running now. Where this log
> and `TRUTH.md` disagree, `TRUTH.md` wins.

State as of **2026-10-07 ~23:30**, on **macbook-pro-2009-nixos** (MacBookPro5,1,
kernel **7.2.3**, EFI, host config `machines/macbook-pro-2009/`).
Pinnacle PCTV 320cx ExpressCard, **2304:022e**, enumerates as **usb 1-3**
(EHCI port 1; the handover before this one said 2-3 — it is 1-3).

> **This host has no autoRollback** — `nixos-confirm` is *not* needed here.
> (That is zen3-nixos.)

---

# UPDATE 2026-10-08 ~13:00 — "the card is not in V4L" was qv4l2 opening the wrong node; two enumeration defects fixed; the module can no longer be reloaded

Kernel is **7.2.9** now (this section's predecessor said 7.2.3), and the card
came back on **usb 2-3**.  Report: "the PCTV does not show up in the V4L2 test
utility, only the camera".

**It was in V4L2 the whole time.**  `qv4l2` started without arguments opens
`/dev/video0` — `utils/qv4l2/qv4l2.cpp`: `else device = "/dev/video0";` — and
video0/video1 on this host are the iSight, so the Input combo shows only
`Camera`.  The card was `/dev/video3` (the number moved when it re-enumerated
at t≈260 s).  `qv4l2 -d /dev/video3` opens it and shows all four inputs
(`Composite 1/2/3`, `S-Video`) plus the `CX25843` tuner entity; `./pctv-view.sh
--ctl` is the wrapper that finds the node by card name.  Its Ctrl+O dialog is a
plain file picker over `/dev` filtered by `video*`, so it lists bare node names
with no product labels — another way to conclude "the card isn't there".

Two real defects found while checking that, both fixed in `v4l2-glue.c`:

1. **`/sys/class/video4linux/videoN/name` was empty.**  Kernel 7.2.9 changed
   `struct video_device::name` from `const char *` to `char name[64]`
   (`include/media/v4l2-dev.h`) — the driver never set the field at all, so the
   first attempt to set it failed to compile with *"assignment to expression
   with array type"*, which is how the change surfaced.  QUERYCAP was
   unaffected (`pctv_querycap()` copies `info.card` itself), which is exactly
   why `v4l2-ctl -D` showed `Pinnacle PCTV 320cx` while anything enumerating
   through sysfs saw a blank.  Now `strscpy(glue->vdev->name,
   glue->info.card, …)`.
2. **No `v4l/by-id/…-video-index0` symlink.**  `vdev->index` was left unset and
   came out as 1; `60-persistent-v4l.rules` builds the symlink name from
   `$attr{index}`, so the card only ever had `-video-index1` and tools that
   resolve the primary node via `-index0` skipped it.  Now `glue->vdev->index =
   0`.  Not yet verified live — see the unload blocker below.

**Blocker, new and open: the loaded module cannot be unloaded.**  `refcnt` stays
at **1** with no interface bound and no node open (opening `/dev/video3` takes
it to 2, closing returns it to 1), so `rmmod` fails with "Module is in use" and
`insmod` then fails with "File exists" — which `reload-module.sh` used to report
as the udev race.  It is not the race: on this kernel neither a registered
`usb_driver` nor its bound interfaces pin the module (`btusb`: 3 interfaces
bound, refcnt **0**), so the reference is the driver's own and nothing ever
drops it.  Where it is taken is **unidentified** — the disconnect path
(`pctv_glue_unregister` → `vb2_video_unregister_device`, then
`video_device_release`, which is the documented pattern per the
`video_register_device()` kernel-doc note) looks normal.  Until that is found,
the rmmod/insmod loop only works in a boot where the card was never probed; a
rebuild lands via `nixos-rebuild switch` + reboot.

Scripts: `reload-module.sh` hardcoded `lib/modules/7.2.3/updates/pctv320cx.ko.xz`
— dead the moment the kernel moved, and it reported that as "no module".  It now
resolves the `.ko*` from the build output (any version, any compression), refuses
a build whose kernel differs from `uname -r` instead of letting insmod fail with
vermagic noise, and prints the stuck-refcnt diagnosis above.  `build-module.sh`
now reports the kernel the module was built for and warns when it is not the
running one.  (This module has no `srcversion` field, so "did my build load?"
is answered by a dmesg marker, not by comparing srcversions.)

The card is still **cold-wedged** this boot (`GET_VERSION: errno -32`,
`fw record … failed: errno -71` once mid-download, `DiB0700 firmware download
failed (errno -5)`), so the node registers — probe deliberately keeps the node
on bring-up failure — but capture stays dark until §0 (power off, pull the
card) is done.

---

# UPDATE 2026-10-08 ~02:00 — vertical jiggle diagnosed and fixed; chroma ramp explained

Two follow-up defects reported on the live picture, both traced to their
root cause and one fixed in the driver (details: FINDINGS §14).

1. **A few lines of vertical jiggle on a still source.** Mode 2 drops ~5%
   of active lines, and the deframer (a) keyed the field boundary on the F
   bit, which the CX25843 flips one line early - if the bridge drops that
   lone line the boundary slips a whole line - and (b) wrote survivors
   straight into their nominal rows, so every drop pulled everything below
   it up.  `pctv320cx.rs` now delimits fields by the **V blanking run**
   (alternating output parity) and **resamples each field onto the fixed
   288-row grid** from a `vmalloc` scratch buffer (288 x 1440 bytes), 8-bit
   linear interpolation.  `finish_frame()` also guards a null vb2 buffer,
   and `op_set_std()` resets the deframer.
   Hardware result (15 s driver capture): **25.00 fps** (was 26.4),
   consecutive-frame vertical shift **0 for 99/119** frames (was ±2..±12),
   even/odd mismatch ~37 -> 3-6.
2. **The chroma "gets worse after a few seconds".** `0x401` bit 7 is the
   chroma-AGC fast-lock bit.  With `0x401 = 0x40` the edge-chroma magnitude
   walks in over ~4 s (21 -> 3.5) then flat; with `0x401 = 0xc0` it is
   pinned from field 1.  **The driver already uses `0xc0`**, and a 20 s
   driver capture was flat (31.0-31.3 per 25 frames), so the ramp is only
   visible on the libusb path when run with `0x40`.  The constant rainbow
   fringe that remains on hard edges is cross-luma from the (chroma-free,
   §12) DVD menu, not a time-varying defect.

**Verified on hardware**: module `…-fan7qif8…`,
`sha256 a5332ca7cb2bb65e…`.  The follow-up robustness build
`…-zfnqlqch…`, `sha256 6d26c687a70adb9a…` built clean but could not be
run: the host hard-crashed and rebooted during the final rebuild (no oops
on the previous boot; nouveau BAR fault ~8 min earlier when qv4l2 was
killed) and came up with the DiB0700 **cold-wedged**, so §0 (physical
power-off) is needed before the next hardware run.

---

# UPDATE 2026-10-08 ~01:15 — the green cast and the roll are fixed

The picture was a solid green, vertically torn and rolling. Two independent
bugs, both in the pointer's assumptions about the BT.656 stream:

1. **The frame buffer was UYVY, advertised as YUYV.**  The CX25843 emits
   `Cb Y Cr Y`; the glue set `V4L2_PIX_FMT_YUYV`, so every consumer read the
   chroma bytes as luma and the luma bytes as chroma — mid-grey luma with a
   large negative Cb/Cr, i.e. saturated green.  `v4l2-glue.c` now sets
   `V4L2_PIX_FMT_UYVY` (both `g_fmt` and `enum_fmt`), and the scripts that
   fed ffmpeg (`test-driver.sh`, `pctv-view.sh`) use `-pix_fmt uyvy422`.
   `decode-bt656.py` always knew this (`Y = pay[:,1::2]`).
2. **The deframer tested the wrong status bit and ignored V.**  In the
   BT.656 SAV/EAV status byte `FF 00 00 XY`, H is **bit 4** (`0x10`), V is
   **bit 5** (`0x20`), F is bit 6.  The old code tested **bit 0** (a
   protection bit) as H: that accepted the EAV code `0xda`
   (`F=1,V=0,H=1`) as an active line and rejected the field-2 SAV `0xc7`
   (`F=1,V=0,H=0`) — torn, de-interleaved picture.  It also copied V=1
   vertical-blanking lines (their 1440 bytes are blanking level) and
   completed a frame on a **line count** (`288*2`), so the ~5% of mode-2
   lines the bridge drops pushed the boundary a little further into the next
   frame every time: the roll.

   `pctv320cx.rs` now tests H correctly, skips V=1 lines, and completes a
   buffer on the **field boundary** after both fields are captured
   (`Deframer { lines, field, fields }`).  It also discards one startup
   frame (`preroll`) so the first buffer handed to userspace is complete
   instead of half a field plus zero fill.

Verified on hardware: `v4l2-ctl -d /dev/video0 --stream-mmap` now reports
`Pixel Format: 'UYVY'`, the first delivered frame is whole, both fields start
on row 0/1, and Cb/Cr stay at 127.7/126.0 (`Y` 78) across 10 frames with no
phase drift.  Rendered via ffmpeg it matches
`snapshots/2026-10-07-menu-composite-colour.png`.

Built into **generation 15** (`nixos-rebuild boot ... --max-jobs 4 --option
builders ''` — the zen3 builder rejected the SSH key this time); the module
sha256 is byte-identical to `/tmp/pctv-result`.

---

# UPDATE 2026-10-08 ~00:10 — the driver WORKS on hardware

**Analog capture through `/dev/video0` is live.** `test-driver.sh` reports
LOCKED and captures 10 clean frames; the decoded PNG shows real content.
No power-cycle was needed: the card had recovered on its own via a hot
re-seat (device 7, t≈4641 s) where the in-tree driver completed a full warm
init. The wedge in §2 is gone.

## What was actually broken (four real bugs, all fixed)

1. **Wrong streaming mode (the big one).** `stream_start()` armed
   `ENABLE_VIDEO 0f 11 01 00` (analog **mode 1**), but mode 1 hands over only
   the active part of each line as 1444-byte blocks = 15.3 MB/s, far below
   PAL's 27 MB/s, and carries no BT.656 SAV framing. The working arm is
   **`0f 12 01 00` (mode 2)**: whole 1728-byte BT.656 lines at 25.6 MB/s
   (~95% of lines). FINDINGS §11; `capture-live.sh` already knew this.
   **The deframer was always written for mode 2** (1728-byte line stride) —
   it was the arm that was wrong.
2. **Wrong capture endpoint.** The card exposes three bulk-IN endpoints
   (0x81/0x82/0x83, all 512-byte maxpkt). `find_bulk_in_ep()` returned the
   *first* (0x81), which never delivers; only **0x82** streams (FINDINGS
   §11.2, in-tree devices table uses stream endpoint 2). URBs never
   completed, so `STREAMON` just hung. Now it prefers EP 2.
3. **`VB2_BUF_STATE_DONE` was mirrored by hand as `0`** in `pctv320cx.rs`
   (= `VB2_BUF_STATE_DEQUEUED`). `vb2_buffer_done()` therefore warned
   (`videobuf2-core.c:1184`, the *invalid-state* check) on every frame and
   returned the buffers as ERROR, so userspace never got a frame.
   Fixed by moving the state choice into the C glue —
   `pctv_glue_buffer_done(glue, vb, length)` now calls
   `vb2_buffer_done(vb, VB2_BUF_STATE_DONE)` itself, so the Rust core never
   mirrors `enum vb2_buffer_state` again.
4. **Fields were stored sequentially but advertised as interlaced.** The
   deframer wrote field 0's 288 lines then field 1's 288 lines (i.e.
   SEQ_TB) while `pctv_fmt.field = V4L2_FIELD_INTERLACED`. It now uses the
   SAV status F bit (0x40) to place each line at row `2*n + field`, and
   reports the full `sizeimage` (829440) as `bytesused` so raw dumps stay
   frame-aligned.

Also fixed along the way:

* `stop_streaming()` requeues the deframer's half-filled buffer
  (`pctv_glue_buffer_requeue()`), which removes the
  "stop_streaming operation is leaving buffer N in active state" warning.
* `decoder_setup()` had the firmware condition **inverted**
  (`if id != 0x34` loaded the microcode when the chip was *absent*). Now
  `id == 0x34` (CX25843) loads `v4l-cx25840.fw` + post-firmware registers,
  on every probe — the microcode is RAM and dies on power-cycle.
* **Signal-lock logging** (requested): `log_signal_state(stage)` polls
  0x40d/0x40e briefly and logs
  `signal check (bring-up|stream-start): 0x40d = 0x… 0x40e = 0x… -> LOCKED|NO SIGNAL`.
  A healthy composite/S-Video source reads `0x40e = 0x7f`; the intermittent
  connector shows up as `NO SIGNAL` (and then no frames).

## First observed good output

```
GET_VERSION: hw 0x00000066 rom 0x00000011 ram 0x00010200 fw 0x00000000
CX25843 chip id (reg 0x100) = 0x34
signal check (bring-up): 0x40d = 0x84 0x40e = 0x7f -> LOCKED
Pinnacle PCTV 320cx analog capture ready
signal check (stream-start): ... -> LOCKED
streaming on endpoint 0x82: 8 URBs submitted
```

`test-driver.sh` → 720x576 YUYV interlaced, 10 frames = 8 294 400 bytes,
zero `videobuf2` warnings, PNG at `/tmp/pctv-driver-test.png`.

## New/changed helper scripts

* `reload-module.sh` — unbinds, `rmmod`, `insmod /tmp/pctv-result/...` and
  retries if udev wins the race (otherwise the *installed old* module gets
  modprobed back in and `insmod` fails with "File exists" while the old code
  keeps running — this bit us once).
* `build-module.sh` — still builds via the flake, but now **falls back to a
  local build** (`--max-jobs 4 --option builders ''`) when the remote
  builder fails (zen3 was out of disk: rustc "No space left on device").
* `test-driver.sh` — finds the node by card name (here `/dev/video0`, not
  video2/3 which are the iSight camera) and captures via `v4l2-ctl`.

## Still open

* **Cold boot / wedge retest, and the §14.3 robustness build.** The card
  was cold-wedged at the end of the 2026-10-08 session, so the final module
  (`…-zfnqlqch…`) has not been run and the cold-boot
  firmware-download path has still not been re-tested since the fixes.
  Do §0, then re-check fps (expect 25.00), the absence of vertical jiggle,
  and that `0x401` is `0xc0` after probe (the driver sets it; the chroma
  ramp only appears if something clears bit 7).
* **Cross-luma fringe on hard edges** remains (constant, not a ramp): the
  DVD-menu source has no true chroma (§12), so this is decoder peaking /
  cross-colour.  §10.10's `luma_lpf=3/uv_lpf=0/comb=0x40` was never tried
  in the driver; a module parameter for `0x47a`/`0x47b` would let it be
  A/B'd from userspace.
* ~5% of lines are dropped (mode-2 bandwidth ceiling).  The resampler now
  hides the vertical effect but does not recover the lines; a true fix
  would need a streaming mode that fits PAL's 27.0 MB/s.
* The `0x401` AGC distinction above should be kept in mind when comparing
  libusb captures (`capture-live.sh` uses `0x40`) against the driver
  (`0xc0`): they are not the same decoder state.

---

## 0. Do this first

The card is **wedged** (§2). Everything in §3–§4 is ready; nothing can be
validated until the DiB0700 gets a real power-off.

1. `sudo poweroff`, pull the ExpressCard, wait ~60 s, re-insert, power on.
2. `cd ~/nixos-config/pctv-linux && ./test-driver.sh`
3. Read `sudo dmesg | grep -iE "pctv320cx|cx2584|dib0700"`. The lines that
   matter, in order:
   - `GET_VERSION: hw 0x… rom 0x… ram 0x… fw 0x…` → bridge 8051 alive
     (healthy card: `hw 0x66…`, rom 0x11, fw 1.2.00)
   - `bridge firmware blob: 33768 bytes` / `downloaded 1610 firmware records`
     → cold card, download ran
   - `CX25843 chip id (reg 0x100) = 0x34` → I2C tunnel + decoder alive
   - `Pinnacle PCTV 320cx analog capture ready` + a `/dev/videoN` node
4. If a node appears: `v4l2-ctl -d /dev/videoN --all`, then the ffmpeg 10-frame
   grab at the bottom of `test-driver.sh`.

## 1. Current state

* **Driver**: `pctv-linux/driver/` — Rust core `pctv320cx.rs` (~1800 L) + C
  V4L2 glue `v4l2-glue.c` (~620 L) + `usb-shim.c` (~180 L), seam header
  `pctv320cx.h` (~200 L), kbuild with bindgen bindings. Builds clean (only
  bindgen's own `unnecessary transmute` noise).
* **Git**: the driver (green cast, roll, and the §14 field-resample fix) is
  committed; see the update sections above for the per-session hashes.
* **Installed**: `nixos-rebuild boot --impure --flake .#macbook-pro-2009-nixos`
  → generation 12 is the default boot entry. The 2026-10-08 resample build
  was run from `/tmp/pctv-result` (module `…-fan7qif8…`) rather than
  installed into a generation; re-install once the cold-wedge retest passes.
* **NixOS wiring** (`pctv-linux/nixos-module.nix`, enabled in
  `machines/macbook-pro-2009/default.nix`): `hardware.pctv320cx.enable = true`
  → `boot.extraModulePackages` + `boot.kernelModules = [ "pctv320cx" ]` +
  `hardware.enableRedistributableFirmware` +
  `boot.blacklistedKernelModules = [ "dvb_usb" "dvb_usb_dib0700" ]` + host's
  `boot.extraModprobeConfig = ''install dvb_usb_dib0700 false''`.
* **Firmware**: `/run/current-system/firmware/` has
  `dvb-usb-dib0700-1.20.fw.zst` and `v4l-cx25840.fw.zst`;
  `CONFIG_FW_LOADER_COMPRESS=y` so the `.zst` forms are found and decompressed
  in place — no unpacking step needed.
* **Last observed probe output** (fixed module, wedged card):
  ```
  pctv320cx: GET_VERSION: errno -32 - bridge is cold
  pctv320cx: bridge firmware blob: 33768 bytes
  pctv320cx: downloaded 1610 firmware records (33763 bytes)
  pctv320cx: GET_VERSION: errno -32 - bridge is cold
  pctv320cx: bridge did not answer GET_VERSION after jumpram
  pctv320cx: DiB0700 firmware download failed (errno -5)
  pctv320cx: Pinnacle PCTV 320cx analog capture ready
  pctv320cx: analog bring-up incomplete - capture will stay dark
  ```
  i.e. the download path is clean end-to-end; only the 8051 start is missing.

## 2. The blocker: the DiB0700 is wedged (not a driver bug)

Proof it is the card, established by A/B on the same hardware state:

* `insmod /run/booted-system/kernel-modules/lib/modules/7.2.3/kernel/drivers/media/usb/dvb-usb/dvb-usb-dib0700.ko.xz`
  (the in-tree DVB driver; `modprobe` is blocked by the `install … false` rule,
  deps `mc dvb-core dvb-usb dibx000_common dib3000mc dib0070 dib0090 dib7000m
  dib9000` load fine) gives:
  ```
  dvb-usb: found a 'Pinnacle Expresscard 320cx' in cold state, will try to load a firmware
  dib0700: firmware started successfully.        <- jumpram return only, NOT verified
  dvb-usb: found a 'Pinnacle Expresscard 320cx' in warm state.
  dib0700: stk7700ph_frontend_attach: i2c_enumeration failed.  Cannot continue
  ```
  and immediately after, `pctv_probe ver` → `Pipe error`. **The in-tree driver
  gets no further than we do.**
* `pctv_probe fw firmware/win_fw.bin` (the Windows blob, 1624 records) also
  starts nothing.
* Bulk OUT + jumpram are always accepted; only EP0 vendor IN (`GET_VERSION`)
  stalls (EPIPE). That is the wedge signature in FINDINGS.md.

Did **not** help: `pctv_probe reset` (libusb port reset), unbind/rebind,
`echo 0|1 > /sys/bus/pci/slots/5/power` (no-op — device number unchanged),
`pctv_probe raw out 9 1` (module-reset attempt; the tool core-dumps on that
subcommand — probe.c arg-parsing bug, not worth fixing), and a quick hot
re-seat (re-enumerated as device 6, still cold — the slot did not cut VBUS).

**Only a real power-off of the slot fixes it** → §0 step 1.

## 3. Bugs found and fixed on the first hardware run

All in `pctv-linux/driver/`, all real, all verified against kernel 7.2.3 source.

| # | bug | fix |
| --- | --- | --- |
| 1 | `request_firmware` got `pctv_dev_get_drvdata(intf as *mut device) as *mut device` — double translation of the same slot, NULL at probe time → -EINVAL ("is v4l-cx25840.fw installed?") | `let dev = &mut (*self.intf).dev as *mut bindings::device;` (both fw sites). Note: `&raw mut` is rejected by this kernel's Rust edition |
| 2 | vb2 queue had no timestamp type → `WARNING: videobuf2-v4l2.c:921` in `vb2_queue_init` | `.timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC` in `glue_init_vb2` |
| 3 | bulk OUT straight from the firmware blob (vmalloc for 33 KiB) → `WARNING: include/linux/dma-mapping.h:523` "rejecting DMA map of vmalloc memory"; the first fix (512 B stack array) → `WARNING: drivers/usb/core/hcd.c:1485` "transfer buffer is on stack" | driver-owned **512 B kmalloc'd** staging buffer `fw_buf`, allocated in `alloc_urbs`, freed in `free_urbs`; `bulk_write` copies there. **Rule: every USB payload must be heap memory** |
| 4 | `usb_free_coherent` was passed `(*u.urb).transfer_dma`, and the URBs never set `URB_NO_TRANSFER_DMA_MAP` → double map/unmap → `BUG: Bad page state … pfn:00001` on rmmod (freeing struct pages) | `Urb` stores `dma` from `usb_alloc_coherent`; new shim `pctv_urb_use_coherent(urb, dma)` (in `usb-shim.c`) sets `transfer_dma` + `URB_NO_TRANSFER_DMA_MAP` after `usb_fill_bulk_urb`; `free_urbs` uses `u.dma` |
| 5 | `GET_VERSION` sent `wValue=0x0281 wIndex=0x0300 len 4` (that pair belongs to the I2C tunnel requests) | in-tree form: vendor IN `0x15`, **wValue = wIndex = 0, wLength = 16** (hw/rom/ram/fwtype); now logged |
| 6 | `cx_r` (CX25843 read) put the **register in wIndex** and sent no sub-address write — wIndex is the bus/config byte (bits 4-5 = bus mode; reg 0x100 ⇒ bus 0 = EEPROM bus) | two-transaction form proven by `pctv_probe cxg_r`: gate open → `13 88 (start, NO stop, len 2) 10 reg_hi reg_lo` → `ctrl_in 0x12 wValue=((stop\|1)<<8)\|0x88 wIndex=0x10 len 1` → gate close |
| 7 | `SET_CLOCK` byte1 `0xf0` (pll_src=1, Windows trace) | `0xb0` = `dib0700_ctrl_clock(72, gp3=1)`, matches `pctv_probe clock` |
| 8 | analog arm `0f 12 01 00` | **`0f 11 01 00`** — byte1 = `(on<<4)\|analog`; `0f 10 11 00` is the MPEG master-mode form |
| 9 | `board_init` drove **GPIO6 low and never raised it** — GPIO6 is the bridge power/enable line (in-tree: "we leave the device on GPIO6") | `gpio(6, out, 1)` first, then 9=1, 4=1, 7=1, 10 pulse, 0=1 |

Also added: staged bring-up logging (`probe_hardware` names the failing stage +
errno; `load_bridge_firmware` logs blob size, record count, failing record;
`decoder_setup` logs the chip id), and `kernel::pr_*!` strings no longer repeat
the `pctv320cx:` prefix (the macro adds it).

## 4. Build / test loop

```sh
cd ~/nixos-config/pctv-linux
./build-module.sh          # nix build of driver/package.nix -> /tmp/pctv-result (~5 min)
sudo rmmod pctv320cx       # the interface unbinds with it (no bind/unbind attrs exist)
sudo insmod /tmp/pctv-result/lib/modules/7.2.3/updates/pctv320cx.ko.xz
sudo dmesg | tail -20
```
* ⚠️ If no pctv320cx is loaded and the card re-enumerates, **udev auto-loads the
  installed (old) module from the store** — always `insmod` the `/tmp` build
  afterwards.
* `nixos-rebuild boot --impure --flake .#macbook-pro-2009-nixos` puts the
  current code into the next boot entry (no `switch` needed; the module is only
  used at probe time). No confirm on this host.
* Userspace fallback while the module is unbound:
  `sudo ./pctv_probe <cmd>` (`ver`, `fw <file>`, `clock`, `i2cparam`, `scan`,
  `cxr <reg>`, `cxw`, `gpio`, `arm`, `cap`, `reset`, `watch`). Rebuild with
  `pctv-linux/build.sh`. It detaches the kernel driver by itself.
* Kernel source for cross-checking:
  `tar -xJf /nix/store/qnp0zhpgbabb9m9c900cai61b3hwfxn8-linux-7.2.3.tar.xz -C /tmp <paths>`
  (`linux-7.2.3-dev` has **no** source). Useful: `drivers/media/usb/dvb-usb/dib0700_core.c`,
  `dib0700_devices.c`, `dvb-usb-firmware.c`, `drivers/usb/core/hcd.c`,
  `include/linux/dma-mapping.h`, `drivers/media/common/videobuf2/videobuf2-v4l2.c`.
  `/tmp` is wiped by a reboot.

## 5. Bring-up sequence (reference — do not re-derive)

Cold card: `GET_VERSION` stalls → download `dvb-usb-dib0700-1.20.fw` as records
`[len][addr_hi][addr_lo][type][data:len][chk]` over **bulk OUT EP1** (raw record
bytes, byte-identical to `dvb_usb_get_hexline` + `dib0700_download_firmware`)
→ jumpram `[08 00 00 00 70 00 00 00]` → 500 ms → `GET_VERSION` answers.

Then `board_init`: `SET_CLOCK 0b b0 …` (72 MHz, gp3) → `SET_I2C_PARAM 0x10`
(100 kHz) → GPIO 6=1, 9=1, 4=1, 7=1, 10↓10↑, 0=1.

CX25843 (7-bit **0x44**, 8-bit 0x88) behind the bridge gate (write to bridge
pseudo-address 8-bit **0x80**, data `04 01 (addr7<<9)>>8 (addr7<<9)&0xff`; close
with `04 01 01 00`): chip id reg **0x100 = 0x34** → upload `v4l-cx25840.fw` →
`std_setup` (timing block 0x470-0x47f) → `input_setup` (reg **0x103** mux;
**0x401 = 0xc0** — colour killer off, vendor's 0x60 gives grey) → controls
(brightness 0x414, contrast 0x415, saturation **0x420/0x421 = val<<1**,
hue 0x422) → streaming: `release_channels` (`0f 00 01/02/04/08 00`) then
`enable_video` **`0f 11 01 00`**, 8 × 64 KiB coherent bulk-IN URBs on **EP2 IN**
(0x82) → `deframe()` BT.656 SAV/EAV → YUYV 1440 B/line, 288 active lines/field
PAL, 1728 B/line on the wire.

V4L2 face: `/dev/videoN`, YUYV 720x576 (PAL) / 720x480 (NTSC) interlaced,
4 inputs (composite1-3, S-Video), controls brightness/contrast/saturation/hue,
vb2-vmalloc, `min_queued_buffers = 2`.

**Verified byte-identical to the in-tree driver / `probe.c`** (do not "simplify"
these): firmware record loop, jumpram, `NEW_I2C_WRITE`/`NEW_I2C_READ`
encodings (`record[3] = 0x10` = frontend bus), `i2c_gate`, `cx_burst`,
`SET_GPIO`, `SET_I2C_PARAM`, `SET_CLOCK`, `ENABLE_VIDEO` arm.

## 6. Likely next failures

1. `GET_VERSION` answers but `CX25843 chip id` errors → I2C tunnel/bus problem:
   compare with `pctv_probe cxr 0x100` side by side (module unbound).
2. Chip id ≠ 0x34 → wrong bus byte or gate; try `pctv_probe scan3` / `cxr`.
3. Node appears, capture times out → check the `dropped` counter (`debug`
   module param, u32, default 1) and the deframer's resync log; then re-sweep
   `ENABLE_VIDEO` payloads with `pctv_probe armsweep`.
4. Card enumerates with a **different product id** → DiB0700 in ROM mode,
   power-cycle.
5. `fw_buf` is allocated with the URB pool in `alloc_urbs()` (probe path, before
   `probe_hardware`); if that ordering ever changes, `bulk_write` returns
   -EOVERFLOW instead of sending.

## 7. Housekeeping

* Scratch/untracked in the repo (leave alone): `pctv-linux/{FINDINGS.md,
  README.md, probe.c, pctv_probe, *.py, *.sh, logs/, driver2/, firmware/,
  snapshots/}`, `PCTV 72e 320cx.zip`, `Pinnacle_TVCenterProSetup_5.4.0.3032.exe`,
  `docs/pctv-320cx.md`, `scripts/pctv-*`, `result*`.
* `FINDINGS.md` (2400 lines) is the full reverse-engineering record; **§13**
  covers the kernel port and the 7.2.3 Rust API workarounds (no
  `vb2_ops.wait_prepare`, `min_queued_buffers`, 2-arg `vb2_streamon`, no
  `vidioc_enumstd`, no `vb2_get_timestamp`, `v4l2_device.dev` is a pointer,
  `usb_alloc_coherent` arg order, `get_unmapped_area` not exported, `module!`
  needs plain `"..."` literals and integer-only params, `KBox::pin_init` →
  `get_unchecked_mut()`).
* Not upstream-ready: no `rustfmt` run (no rustfmt in the build env,
  "Failed to run rustfmt … (non-fatal)"), and `#![allow(unsafe_op_in_unsafe_fn)]`
  at the crate top is a pre-upstream cleanup item.
* The Win7 VM and its USB-passthrough helpers are retired.

---

# UPDATE 2026-10-08 ~13:45 — the bridge is cold at the instant of insertion; the download shape is not the problem

Report: "the PCTV is no longer capturing video through V4L2 since the kernel
update". Kernel is **7.2.9** (`Linux 7.2.9 #1-NixOS SMP`), card on **usb 2-3**
(EHCI `0000:00:06.1`), module auto-loads on insertion (it is in
`boot.extraModulePackages` via `hardware.pctv320cx.enable`).

**What the V4L2 layer does.** The node is there and correct — the previous
section's two enumeration fixes are live: `/dev/video0`,
`Card type: Pinnacle PCTV 320cx`, `/dev/v4l/by-id/usb-Pinnacle_system_PCTV_320cx_0000000100-video-index0`.
`v4l2-ctl -d /dev/video0 --stream-mmap` fails at stream-on with

```
pctv320cx: signal check (stream-start): decoder did not answer (0x40d errno -32, 0x40e errno -32)
pctv320cx: arming the bridge anyway, but no signal is locked
WARNING: CPU: 1 PID: ... at .../videobuf2-core.c:... vb2_start_streaming+0xae/0x130
```

so the capture path is dark for the same reason as before: **the DiB0700 does
not answer**, and the CX25843 decoder is therefore unreachable over the i2c
tunnel. (The `vb2_start_streaming` WARN is a separate driver-side bug — we arm
and start streaming on a dead bridge instead of failing the request; still open.)

**The bridge state, measured with the kernel driver off the device.** After a
physical pull + re-insert (device number 4 → 6) with `pctv320cx` rmmod'd, so
that `pctv_probe`/`fwtest` is the *very first* accessor after enumeration:

| Access | Result |
| --- | --- |
| descriptors, strings, high-speed enumeration | fine (`480 Mbit`, "PCTV 320cx", serial `0000000100`) |
| `0x15 GET_VERSION`, recipient 0 **and** 4 | `EPIPE` (stall) |
| `0x02` legacy i2c (the EEPROM read the Windows driver does on a fresh card) | `EPIPE` |
| `0x09 RESET`, `0x0a MASTER_RESET` (control OUT) | `EPIPE` |
| bulk OUT EP1 firmware records | accepted, 0 errors, 1610 records |
| `0x08` jumpram | accepted; EP1 IN then reports one constant 12 bytes `00 00 00 00 70 00 00 00 06 4a 3e e4` |

FINDINGS §1 records that this card **self-boots its firmware from the config
EEPROM** — `hw=0x66 rom=0x11 ram=0x00010200`, no download needed — and that
GET_VERSION answered on a freshly powered card. It no longer answers *at all*,
so the 8051 is not running even at power-on, and the download cannot revive it.

**Ruled out on the host side** (all with `pctv-linux/fwtest.c`, new this
session; build line in its header):

* transfer shape — per-record short packets (mainline shape), one continuous
  stream in full-512-byte chunks, and every record sent twice (data-toggle
  resync): all accepted, none starts the 8051.
* `clear_halt` on EP1..EP3 both directions; bridge `RESET`/`MASTER_RESET` after
  the download.
* USB port reset (`libusb_reset_device`) — succeeds, card stays cold.
* unbind/rebind `ehci-pci`; PCI runtime PM of the EHCI (`power/control=auto` →
  **D3hot held 60 s**). Note what that proved: the card re-enumerated after the
  D3hot cycle **without ever losing power**, so the ExpressCard slot VBUS is not
  switched by the controller's D-state — there is no host-side power cycle
  available, only a physical one.
* the payload never reaches the RAM in a *verifiable* way: the 12-byte EP1 IN
  reply is byte-identical for the stock blob and for a blob with one data byte
  flipped and its record checksum recomputed (`/tmp/fw_patched.fw` recipe in
  this session's transcript), so it is an interrupt report, not a firmware ACK.
  EP1 IN is an **interrupt** endpoint (64 B, interval 10 — FINDINGS §1), which is
  why those reads look like canned replies.

**On "since the kernel update".** The observation is real: the module verified
working on hardware (resample fix, 375 frames @ 25.00 fps) is
`/nix/store/fan7qif8kag65cxawdqqaj6hsymkxwd6-pctv320cx-0.1`, built against
**7.2.3**; the only 7.2.9 builds (`aj4kz2al…`, `kpw6wkzd…`) have never worked.
But the wedge began at the **host hard-crash** that ended the 7.2.3 session
(FINDINGS §14.4 — nouveau BAR fault ~8 min earlier, no oops), and a physical
power cycle does not clear it, which is *not* what the old wedge looked like
(HANDOVER §0 / FINDINGS §7.1: a port reset used to fix it). So the kernel bump
is not proven to be the cause; the card or the slot may simply be dead.

**The two decisive tests, neither run yet.**

1. **Boot the 7.2.3 generation** — `/nix/var/nix/profiles/system-15-link`
   (nixpkgs 26.05.20260903, the last generation before the 12:22 bump; gens
   16/17 are 26.11.20261006 → 7.2.9). Then `sudo rmmod pctv320cx` (udev
   auto-loads it on insertion), pull the card, re-insert, and make
   `sudo ./pctv_probe ver` the first accessor. GET_VERSION answers → 7.2.9 does
   something during enumeration that kills the EEPROM self-boot, and the next
   step is diffing the 7.2.3→7.2.9 usbcore/EHCI enumeration sequence. It
   stalls → the card/slot is dead and no kernel change will help.
2. **Test the card under Windows on this same laptop** (kernel-independent proof
   of card health): the retired `win7` libvirt domain + USB passthrough, driven
   by `scripts/pctv-win7-ssh.sh`. The domain may need recreating.

**Do not** conclude from `dmesg`'s `dib0700: firmware started successfully` that
the bridge is up — that message only means jumpram was *accepted*. GET_VERSION
is the only real health check.

# UPDATE 2026-10-08 ~14:20 — the userspace path WORKS end-to-end; the bridge is cold with **no kernel driver loaded at all**; and it was already cold on 7.2.3

Ran the userspace path (`pctv_probe` + `capture-live.sh`) exactly as asked, as the
sole accessor of the card. It is up and functional — it opens the device, claims
if 0, downloads firmware, jumprams, and would capture. It gets no frames because
the bridge will not run firmware. That is now measured with the kernel module
**off and blocked**, which the previous update's control did not actually do.

**Correction to the 13:45 update.** "`pctv_probe ver` was the first accessor
after a physical power cycle" is **false**. `dmesg` shows udev auto-loading
`pctv320cx` ~0.2 s after enumeration (`usbcore: registered new interface driver
pctv320cx` at 2669.25, `GET_VERSION: errno -32` at 2669.45), i.e. the module
probed the card, ran its own download + jumpram, and *then* the userspace tool
was run. Every cold measurement so far was taken after a module probe.

**How to keep the module off** (needed for any clean measurement):
`blacklist` does **not** stop udev's modalias auto-load. Use an install override:

```sh
echo "install pctv320cx /nix/store/2gfxiwls9hbgwdwcy43mprchwsq36mg6-coreutils-9.11/bin/false" \
  | sudo tee /etc/modprobe.d/99-pctv-test.conf     # temporary; gone on rebuild
sudo rmmod pctv320cx
sudo modprobe pctv320cx   # must fail - that is the check that it is really off
```

**New scripts:** `first-touch.sh` (waits for pull + re-insert, GET_VERSION first,
then captures) and `hold-then-capture.sh` (same, but enforces a *timed* hold so
the slot rails actually drop — a ~10 s hot-swap does not power-cycle the bridge).
Both log to `logs/`.

**Result** (`logs/hold-20261008-141210.log`, module off, 60 s out of the slot):

| step | result |
| --- | --- |
| GET_VERSION as first vendor request after enumeration | `errno -32` (EPIPE) — cold |
| download all 1610 records + jumpram `0x70000000` | accepted, still cold |
| `libusb_reset_device` (port reset) | ok, still cold |
| vendor blob `firmware/win_fw.bin` (1624 records) + jumpram | accepted, still cold |

`fw2` (read EP1 IN after *every* one of the 1610 records) produced **two**
12-byte replies in the whole download — at record 0 and at record 1609 (the EOF
record) — and **nothing at all after the jumpram write**:

```
rec    0 addr 0000 type 04 len   2 -> ack 12: 00 00 00 00 70 00 00 00 07 e4 75 02
rec 1609 addr 0000 type 01 len   0 -> ack 12: 00 00 00 00 70 00 00 00 06 4a 3e e4
```

Same 8-byte head every time, only the last four bytes move, and the two values
alternate between runs — i.e. a small queue of pending reports being drained, not
a per-record loader ACK. Bytes 4–7 are `70 00 00 00` = the jumpram address, so
they are most plausibly the ROM acknowledging an *earlier* jumpram. The image
itself never reports in.

**The kernel update is exonerated — the bridge was cold 14 h before 7.2.9
booted.** Per-boot (`journalctl -b N -k | grep -m1 "Linux version"`):

| boot | kernel | bridge |
| --- | --- | --- |
| -3, Oct 7 **21:47:22** | **7.2.3** | **ALIVE** — module reached `decoder bring-up failed (is v4l-cx25840.fw installed?)`, which is *past* GET_VERSION/i2c |
| -3, Oct 7 **21:58:43** | **7.2.3** | **cold** — `DiB0700 firmware download failed (errno -5)` (first cold sighting) |
| -2, Oct 8 01:52 | 7.2.3 | cold (after the hard crash + reboot) |
| -1, Oct 8 12:32 | 7.2.9 | cold |
| 0, Oct 8 13:16 | 7.2.9 | cold |

The 7.2.3 → 7.2.9 bump was at Oct 8 **12:22**. So the "since the kernel update"
correlation is a coincidence, and **the boot-15 (7.2.3) test in the previous
update is now pointless — skip it.** The card died between 21:47 and 21:58 on
Oct 7, on 7.2.3, and never came back across a reboot and several physical power
cycles — unlike the old wedge, which a port reset cleared (FINDINGS §7.1).

**Where that leaves the path.** The userspace path is the right one and is ready:
the moment GET_VERSION answers, `./capture-live.sh composite1 6 <tag> best`
captures. The blocker is below every driver: the DiB0700's 8051 does not execute
an image in its RAM — not the EEPROM self-boot, not the stock 1.20 blob, not the
vendor's own blob — on a clean power-on with nothing else attached. Both load
paths end in the same silicon, so the fault is the 8051/RAM (or its supply), not
"the firmware" and not the host.

**Remaining tests, all card-vs-slot-vs-machine, none kernel-related:**
1. This card under Windows on this laptop (the retired `win7` domain +
   passthrough, `scripts/pctv-win7-ssh.sh`) — kernel-independent.
2. A different DiB0700 card in this ExpressCard slot (the second tuner in the
   drawer is the same family) — tests the slot.
3. This card in another machine — tests the card outright.

**Real driver bug found while reading 7.2.3 `dib0700_devices.c`** (unrelated to
the cold bridge, but it will matter the moment the card works):
`stk7700ph_frontend_attach()` drives GPIO6 **low** *specifically for the 320cx*
and high for every other board:

```c
if (idVendor == USB_VID_PINNACLE && idProduct == USB_PID_PINNACLE_EXPRESSCARD_320CX)
        dib0700_set_gpio(dev, GPIO6, GPIO_OUT, 0);
else    dib0700_set_gpio(dev, GPIO6, GPIO_OUT, 1);
```

§3 bug #9 ("board_init drove GPIO6 low and never raised it") was therefore
**wrong for this board** — the original low was correct, and `gpio(6, out, 1)` in
`board_init()` is a regression against the 320cx branch. Vendor requests never
reach the GPIO layer on a cold bridge, which is why it has not bitten yet.

---

# UPDATE 2026-10-08 ~14:45 — userspace probe re-run on a full power-off + fresh boot; the bridge is still cold (hardware), and the second-card test is the one that decides it

Requested: "the PCTV has not shown a picture through V4L2 since the kernel
update — fall back to the userspace probe driver (the path known to work) and
capture frames."  Done, on both a long hot power-off and a full machine
reboot.  Every attempt is negative for the same reason as the 14:20 section:
**the DiB0700 bridge is cold** (the 8051 never runs), which is below both the
module and the userspace tool.

## What was run

Module blocked throughout (`/etc/modprobe.d/99-pctv-test.conf`, survives the
reboot; `dvb_usb_dib0700` blocked by `nixos.conf`).  `lsmod` confirmed clean
before each test; the stray in-tree `dvb_usb`/`dib*` modules loaded by the
control experiment were `rmmod`'d afterwards.

| test | result |
| --- | --- |
| Hot power-off, ~170 s out, `pctv_probe ver` first | `GET_VERSION … Pipe error` (cold) |
| `pctv_probe init firmware/dvb-usb-dib0700-1.20.fw` | records accepted; every `ctrl_in rq=0x12` stalls; `scan done: 0 device(s)` |
| ROM-path EEPROM read (`eeprom`, `c4 02 01a0`) | every read `Pipe error` |
| `pwron all` / `demodreset` | every vendor write `Pipe error` |
| `pctv_probe reset` (USB port reset) + `ver` | ok, still cold |
| **Full machine power-off, boot with card OUT, then insert** (`first-touch.sh`) | cold (see below) |
| In-tree `dvb_usb_dib0700` insmod'd | `firmware started successfully` / `warm state`, then `stk7700ph_frontend_attach: i2c_enumeration failed`; `GET_VERSION` still stalls; no frontend, only a dangling `dvb-demux` |
| descriptor sanity | sane (`PCTV 320cx`, 1 interface, high-speed) — the bus is physically fine |

## The fresh-boot run (the strongest test we can do without another card)

`./first-touch.sh composite1 6 5` after a full reboot with the card out:

```
[14:38:54] present: Bus 002 Device 003: ID 2304:022e …
[14:38:54] step 3: GET_VERSION (first vendor request after enumeration)
device 2304:022e not found (or held by qemu/usbfs).
...
[14:38:54] BRIDGE COLD at first touch …
  ctrl_in rq=0x15 value=0x0000 index=0x0000 -> Pipe error
GET_VERSION failed -> device is COLD (no firmware running)
```

The "not found" is the card **re-enumerating under us**: `dmesg` shows device 3
at 115.88 s, `USB disconnect` 0.12 s later, and device 4 at 116.77 s.  That is
the card resetting its own USB link once and then never bringing up firmware —
not the host disturbing it.  On the settled device 4, four `ver` attempts over
~15 s were all `Pipe error`.

## Verdict

The 8051 does not execute an image — not the EEPROM self-boot, not the stock
1.20 blob, not the vendor blob — and even the ROM-level vendor reads now stall.
It survives a real power cycle and a full-reboot insertion, which the *old*
wedge (FINDINGS §7.1) never did.  So this is hardware: the 8051 core, its
clock/supply, or its EEPROM boot image.  §14.4's remaining tests stand, unchanged:

1. **A second DiB0700 card in this slot** — separates dead-card from dead-slot.
2. **This card in another machine** — confirms the card.
3. If a second card is cold in this slot too, suspect the slot/controller (the
   hard crash that preceded this may have damaged it); if it works, this card is
   dead and a USB composite/S-Video dongle is the pragmatic replacement.

The userspace path stays ready and correct — the moment a healthy card answers
`GET_VERSION`, `./first-touch.sh` (or `./capture-live.sh composite1 6 <tag> best`)
captures.  No kernel change is involved: the bridge went cold on 7.2.3 the night
before the 12:22 bump (14:20 section, per-boot table), and the 7.2.9 module and
the userspace tool fail at the identical point.

Host left clean: no `pctv320cx`, no `dvb_usb_dib0700`, no `/dev/video*`, no
`/dev/dvb`.  `first-touch.sh` / `hold-then-capture.sh` remain the scripts for the
next attempt (both log to `pctv-linux/logs/`).

---

# UPDATE 2026-10-08 ~15:05 — **the bridge came back to life**, and the thing that revived it was the **Windows driver in the win7 VM**

Requested: "beginning to suspect the pctv is broken — bring up the w7 VM and see if
it is alive."  The VM is alive, and it answered the open §14.4 question (test 1,
"this card under Windows on this laptop"): **the card is not proven dead.**

## The VM

`win7` was **shut off**, not deleted — the domain, its qcow2
(`/var/lib/libvirt/images/win7.qcow2`, 17 GB allocated) and the `hostdev`
passthrough entry are all intact, so nothing had to be recreated.

```sh
virsh -c qemu:///system start win7          # started in ~45 s, lease 192.168.122.59
./scripts/pctv-win7-ssh.sh 'whoami & ver'   # chris-pc\chris, 6.1.7601 — SSH works
```

Guest state with the card attached (`virsh qemu-monitor-command win7 --hmp "info usb"`
→ `Device 0.2, Port 4, Speed 480 Mb/s, Product PCTV 320cx, ID: hostdev0`):

| check | result |
| --- | --- |
| `Ltn_hyd7700pc_64` (DiBcom 7700P kernel driver) | **RUNNING**, `ConfigManagerErrorCode 0`, device `Status OK` |
| `Ltn_rc_64` (IR receiver) | RUNNING, OK |
| `USB\VID_2304&PID_022E\0000000100` | present, bound, no error |
| `dsenum.exe` | `PCTV DiB BDA Analog Capture` + `PCTV DiB BDA Analog Audio Capture` enumerate |
| System event log (this boot) | no device/driver errors — only the two "unclean shutdown" records from the Oct 7 power-off |

Do **not** read too much into the guest's `…&FN_01` / `HID\VID_2304…COL01..04`
nodes: the host's descriptor read still shows `bNumInterfaces 1`, 4 bulk
endpoints, no IAD, so those composite instances are Oct-6/7 leftovers that WMI
keeps listing (Win32_PnPEntity and even Win32_USBControllerDevice associations
survive for installed-but-absent devices).  PnP "OK" is not a bridge health
check — GET_VERSION is.

## The finding

After `virsh detach-device` handed the card back to Linux, the host measured —
for the first time since Oct 7 21:58, i.e. after ~20 h and several physical
power-offs of nothing but EPIPE:

```
$ sudo ./pctv_probe ver
  ctrl_in rq=0x15 value=0x0000 index=0x0000 -> 16
GET_VERSION: 16 byte(s):
  0000: 00 00 00 66 00 00 00 11 00 00 00 01 00 00 00 00
  hw=0x00000066 rom=0x00000011 ram=0x00000001 fwtype=0x00000000
```

and it kept answering — 9 of 10 consecutive `ver` calls over 40 s.  **The 8051
was executing.**  Nothing on the Linux side did that: the only thing that had
touched the card in between was the Windows driver inside the guest.

Note `ram=0x00000001`, not the healthy `ram 0x00010200` of §"First observed good
output" — the image now running is not the 1.20 blob's.  Worth pinning down
(which blob the Windows driver loads, and whether `ram` is a version at all).

## ⚠️ The later "it went cold again" readings are NOT trustworthy — two usbfs clients

Everything measured after the detach is contaminated:

```
$ for p in /proc/[0-9]*; do ls -l $p/fd | grep -q /dev/bus/usb/002 && echo "$p $(cat $p/comm)"; done
PID 2391 .virt-manager-w:   /dev/bus/usb/002/010      # a virt-manager window holds the card
PID 2501 .qemu-system-x8:   /dev/bus/usb/002/010      # and qemu, after re-attach
```

That is why every `pctv_probe` printed `claim if0: Resource busy`, and it
explains the two "degraded" results I reported in-session:

* `fw download failed at 0: Input/Output Error` — dmesg says the real reason:
  `usb 2-3: usbfs: process 3646 (pctv_probe) did not claim interface 0 before
  use`.  Bulk OUT on an unclaimed interface, not a dead bridge.
* `ctrl_in rq=0x15 -> Operation timed out` — could be the same contention.

So the sequence "warm → cold again in 2 min" is **unproven**.  The card may
still be warm.  Re-measure with exactly one accessor.

## How to re-run this cleanly

1. Close the virt-manager window that holds the card (PID 2391 at the time of
   writing) — it is the hidden claimant.  Only one of {qemu, pctv_probe, the
   kernel module} may hold the device.
2. Detach from the guest with a **vid/pid** XML, not the `dumpxml` copy: the
   dumped `<source>` pins `bus='2' device='4'` and the devnum changes every
   re-enumeration, so `virsh attach-device` then fails with *"Did not find
   matching USB device"*.  Use `/tmp/pctv-hostdev-vidpid.xml`:
   ```xml
   <hostdev mode='subsystem' type='usb' managed='yes'>
     <source><vendor id='0x2304'/><product id='0x022e'/></source>
   </hostdev>
   ```
   (NB the running domain's own entry is the older pinned form plus a
   `qemu:override` that swaps `hostdevice` for `vendorid/productid/hostport=3` —
   that autoscan is what let qemu re-claim the card across devnum 4→10.)
3. With the card on the host and nothing else holding it: `sudo ./pctv_probe ver`
   → if it answers, go straight to `cxr 0x100` (expect `0x34`) and then
   `./capture-live.sh composite1 6 <tag> best`.
4. If it answers warm, the next question is *what the Windows driver does that
   we don't*.  Capture it: start `sudo cat /sys/kernel/debug/usb/usbmon/2u >
   /tmp/mon.log &` (module `usbmon` is loaded now; no tcpdump on this host),
   then detach + re-attach the card so the guest driver re-runs its bring-up.
   That trace is the recipe to fix `load_bridge_firmware()`/`board_init()`.

## Also observed

* The card re-enumerated by itself 9 times this boot (devnum 4→10, `USB
  disconnect` + `new high-speed USB device` in dmesg, ~40 s–4 min apart) while
  the guest driver and qemu were driving it, and **zero** times during a 150 s
  idle with no accessor.  Consistent with dib0700 firmware-download/jumpram
  churn, not necessarily a flaky slot.
* `pctv_probe cxr` (i2c gate, `ctrl_out rq=0x13`) failed with `Pipe error`
  before the revival and `Operation timed out` after — both under the
  contention above, so the decoder tunnel is still unmeasured this session.
* Host left as: `win7` **running**, card **attached to the guest** (port 4),
  `pctv320cx` still blocked by `/etc/modprobe.d/99-pctv-test.conf`, `usbmon`
  loaded.  Guest evidence bundle: `pctv-linux/logs/guest-w7-alive-20261008.txt`.

---

## Update 2026-10-08 ~15:30 — **answered: Windows does nothing we don't**

(`logs/win7-vs-linux-20261008.md` is the evidence pack; raw trace
`logs/raw-winretry2.bin`, parsed `logs/win7-vs-linux-trace-20261008.parsed`.)

The "Windows driver binary" was finally obtained from the guest
(`--get 'C:/Windows/System32/drivers/Ltn_hyd7700pc_64.sys'`; the earlier note that
it was nowhere on any volume was because it lives only *inside* the VM disk).
With it we could replay and compare apples-to-apples on the same cold card:

1. **Detached the card from the guest** (empty result −110 on first detach, but
the slot recovered by re-binding `ehci-pci`/`ohci-pci`; see "Controller
recovery" below). Host `pctv_probe ver` → `Pipe error`: **cold**, as expected.
2. **Linux cold bring-up** (`pctv_probe init` / `fw firmware/win_fw.bin`):
   1624-record download + `jumpram 0x70000000` **accepted**, then `GET_VERSION`,
   `SET_CLOCK`, every legacy i2c read → `EPIPE`. Cold.
3. **Re-attached to the guest and let the Windows driver run StartDevice** with
   usbmon capturing. Result: the driver's bulk-OUT stream rebuilds to exactly
   `29ccafb3cc2414c02dab8b06f3f5bddd` — **byte-identical to `firmware/win_fw.bin`
   and to our `pctv_probe fw` download** (`cmp` clean). Its entire cold-start
   command sequence is:

   ```
   c4 02 01a1 (len 1)              -> EPIPE   # EEPROM read, pre-download
   1625x bulk OUT ep1              -> all st=0  # firmware + jumpram
   c4 02 01a0 (len 8)              -> EPIPE
   c4 02 01a1 (len 1)              -> EPIPE
   ```

   No reset, no GPIO (`0x0c`), no `SET_CLOCK` (`0x0b`), no `ENABLE_VIDEO`
   (`0x0f`), no `0x44`-recipient request, no DiBcom-only request. **Windows sends
   nothing our Linux probe does not already send, and it fails in the same way.**

So the Oct-8 "revival" was **not** a Windows command, and it was **not a revival
at all**. `ram=0x00000001` is the **ROM bootloader** — mask ROM, so it always
runs — not a working card (healthy is `ram=0x00010200`). This is exactly the
14:20 finding: the DiB0700's 8051 runs its mask ROM but **will not execute any
image in its RAM** — not the EEPROM self-boot, not the stock 1.20 blob, not the
vendor blob — on a clean power-on with nothing else attached. The card has been
in that state since **Oct 7 21:58** (first cold sighting, on the *old* 7.2.3
kernel, 11 min after the last good boot), and no power cycle, port reset, kernel
driver, host download or the Windows driver has brought it back. The 9
device-initiated re-enumerations were the 8051 repeatedly resetting into its ROM.
The Windows trace above is the kernel-independent confirmation of that: a
different OS, the vendor's own driver, identical bytes, identical failure.

**The video/capture path is not the answer either:** its extra init (GPIO + full
DIB7000P register dump + CX25843-style decoder config + `ENABLE_VIDEO analog`,
all already captured in `logs/analog-seq-windows.txt` / `full-seq.txt`) runs only
*after* StartDevice succeeds. On a cold card the driver never gets past
GET_VERSION, so the capture path is never reached. An attempt to force it via
`sc start Ltn_hyd7700pc_64` (the service reports RUNNING; the PnP node stays
`ConfigManagerErrorCode 10`) reached exactly the sequence in §2 above.

### Where that leaves us

* Nothing to add to `load_bridge_firmware()`/`board_init()` from the Windows
trace — they already match it.
* The blocker is **hardware/EEPROM self-boot intermittency in the DiB0700**: the
card only answers when its own ROM boot succeeds, and there is no host command
that forces it. The only reliable host-side actions are the ones that *perturb*
it: full slot power-cycle (ExpressCard pull, ≥60 s) or possibly a warm
re-enumeration storm. `libusb_reset_device` (12×) and `authorized 0→1` (×10)
were both tried and **do not** force a ROM re-boot.
* **Next experiment: run the ROM-window catcher** (`./rom-window.sh 1800
  --hold`, docs `ROM-WINDOW.md`). It watches for the bridge to answer on EP0 and,
  the instant it does, dumps both `GET_VERSION` forms, the **full config EEPROM**,
  `GET_GPIO` and the vendor-request map. That is the one free measurement left:
  it distinguishes "the EEPROM self-boot image is gone" (dump reads `00`/`ff`)
  from "the 8051/RAM no longer executes an image" (dump is intact). Either way,
  save `logs/rom-window-<epoch>/romwin.log`. Nothing else host-side can force the
  ROM to boot.

### Controller recovery (needed every detach on this box)

Detaching a qemu USB hostdev tears down the EHCI/OHCI state and this MCP79
controller does not always re-arm after a bus reset storm (`device descriptor
read/64, error -110` on the port forever). Recovery that worked:

```sh
sudo sh -c 'echo 0000:00:06.0 > /sys/bus/pci/drivers/ohci-pci/unbind'   # background; can block
sudo sh -c 'echo 0000:00:06.1 > /sys/bus/pci/drivers/ehci-pci/unbind'   # background; can block
sudo sh -c 'echo 0000:00:06.0 > /sys/bus/pci/drivers/ohci-pci/bind'
sudo sh -c 'echo 0000:00:06.1 > /sys/bus/pci/drivers/ehci-pci/bind'
```

unbind may report a hung task and the `echo …/bind` may block in `D` for ~60 s;
run them with a `&` and wait — the devices come back (`usb4`, `usb2`) and the card
re-enumerates. `/dev/usbmon2` and `/dev/usbmon4` both exist once `usbmon` is
loaded; capture both buses while a device can flip between EHCI (high-speed) and
OHCI (full-speed) on `.1`.

Host left as: `win7` **running**, card **attached to the guest** (port 4),
`pctv320cx` still blocked, `usbmon` loaded, watcher/`cat` stopped.

---

## 2026-10-08 16:20 — the ROM window WAS caught: EEPROM bytes 0..71 are intact, and the index law is `wIndex>>8`

Full write-up: **FINDINGS §16**; tool usage: **ROM-WINDOW.md §0/§3.4**.

`sudo ./rom-window.sh 1800` (dir `logs/rom-window-1791471238/`, usbmon in
`raw-bus2.bin`) caught **19 ROM windows in 4 minutes** without any pull — the card
was enumerated and re-enumerating on its own. Four results:

1. **`GET_EEPROM` answered inside the windows**: 2048 reads per window, 0 errors,
   19 dumps byte-identical. First EEPROM content ever read off this card.
2. **The read is a sliding window: the 8 bytes start at EEPROM byte `wIndex>>8`.**
   The ROM's index register is the *high byte* of `wIndex`, **8 bits**, wrapping
   (12 index points + the byte-255 wrap). The old `eepromdump` (`wIndex = offset`)
   re-read the same byte 32 times — the "16 KiB dump" was really **bytes 0..70**,
   and 16-bit `wIndex` caps this request at **256 bytes**. `eepromdump` fixed.
3. **The EEPROM is not `00`/`ff`.** Bytes 0..71 decode cleanly: `d0` marker,
   VID/PID/bcdDevice `2304:022e 0100`, string count 5, the string descriptors
   ("Pinnacle system", "PCTV 320cx", "0000000100"), and a model string **"7700P"**.
   So §15's "self-boot image gone" is *not* supported by what is reachable — the
   decisive bytes are **72..255**.
4. **The wedge has a mechanism:** the vendor-request map probe sends `rq 0x02`
   with `wValue 0` (I2C address byte `0x00`), and from that moment `GET_EEPROM`
   STALLs forever while `GET_VERSION` keeps answering; port reset does not help.
   That is the old "probing every request number wedges the stick" note explained:
   it wedges the ROM's **I2C engine**, not the device. The map is now opt-in
   (`romwin --map`).

Also re-interpreted: **`ram=0x00000001` is a static ROM constant**, identical
before the download, after `firmware: 1624 records` + `jumpram -> ok`, and an hour
later — so "the download is accepted" proves nothing. Only `ram` changing to
`0x00010200` would.

Tools: `pctv_probe eepromwin` (watches for the rarer `GET_EEPROM` service and
grabs the whole 256 B image + a `wValue`/`wIndex` form map hunting a wider index),
fixed `eepromdump`, `romwin --map`, `rom-window.sh --eeprom|--map`. Built clean,
all read-only.

**Host left as:** card enumerated on bus 2 (dev 22), `pctv320cx` blocked,
`win7` running but **not** holding the card, `usbmon` loaded, and a **live
`eepromwin` watch** (`logs/eeprom-window-1791472381/`, 60 min, started 16:13) plus
`cat /dev/usbmon2`. The card sits in the ROM-answers-GET_VERSION / I2C-wedged
state; the watch will not catch anything until the I2C engine is restored.

**Next (needs hands):** pull the ExpressCard ≥ 60 s and re-insert while the watch
runs — that is the only known way to restore the I2C engine — then read
`eeprom-<epoch>.bin` bytes 72..255:

```sh
cd ~/nixos-config/pctv-linux
sudo ./rom-window.sh --eeprom 3600 --hold
```

`00`/`ff` there → the self-boot image really is gone. A plausible firmware record
→ the EEPROM is intact end to end and the fault is the 8051 fetching/executing it
(rail/regulator or the chip), which is where §15 pointed from the Windows side.

---

## 2026-10-08 18:05 — THE PULL WAS DONE: the EEPROM is config-only and blank past 0x4a → the card is bricked at the boot-image level

Full write-up: **FINDINGS §16.7**. Dump: `logs/eeprom-window-1791478844/eeprom-1791478863.bin`.

Pulled ≥ 60 s, re-inserted while `eepromwin` watched; it caught the window on
iteration 3 and read **32/32 windows, 0 bad** — the whole reachable image:

* Bytes **0x00..0x4a**: the config block, byte-identical to the 15:53 reads
  (`d0` marker, `2304:022e`/bcd `0100`, 5 strings, model `05 "7700P"`, ends
  `50 31 01 00`).
* Bytes **0x4b..0xff**: **179 × `ff`** — erased. Only two strays: `0x7f=e3`, `0x80=00`.
* A **second index form** exists: `wValue 0x02a0` = same 8-bit index, **+1 offset,
  no wrap** (`ix=ff00` reads **byte 256**). `0x03a0/04a0/08a0/10a0/20a0` stall, so
  nothing reaches past ~256 — and **byte 256, exactly where an aligned firmware
  image would start, is `ff`**.

Settles the investigation: **EEPROM chip alive** (a pull restores the I2C engine
and it ACKs 32 reads), **boot ROM alive**, **config intact**, **no firmware image
anywhere reachable**, and a clean power cycle still yields `ram=0x00000001` (the
ROM loads nothing). Also confirmed the wedge rule: valid address bytes are safe,
`wValue 0` / odd address bytes wedge the I2C engine until the next pull.

**Conclusion: the card is dead, and reprogramming is not the fix — see §16.8.**
The Oct 6 healthy traces contain **zero** firmware downloads, so the image lives
*inside* the DiB0700; the external EEPROM is only a 256-byte config EEPROM (blank
past 0x4a is normal for it). The host can already hand the chip a byte-identical
image (1625 records + `jumpram -> ok`) and it never runs, so the fault is
downstream of the boot source — the 8051's fetch/execute path or its RAM. The ROM
offers no flash/program/upload service (`0x04/0x06/0x09/0x0d/0x15` only), so there
is no host-visible handle on the internal image. **Replace the card.**

What "recovering it with the win7 VM" actually was: on Oct 6 the card self-loaded
its image and the driver downloaded nothing; on Oct 8 the driver downloaded the
full image and failed identically (§15). `guest-w7-alive-20261008.txt` is a *VM*
liveness probe, not the card working.

**Host left as:** card enumerated on bus 2 (dev 23), `pctv320cx` still blocked by
`/etc/modprobe.d/99-pctv-test.conf`, `win7` running without the card, `usbmon`
loaded, **no watcher running** (the watch ended after its 1 window). To resume any
of this: `sudo ./rom-window.sh --eeprom 600 --hold` and a pull.

---

## 2026-10-08 18:50 — THE CARD IS ALIVE. Written up in **`TRUTH.md`** (now the authority)

Everything the two 2026-10-08 entries above concluded is **retracted**; read
`TRUTH.md` instead of them. Short version:

* **The card has no self-boot image.** At every power-up it is cold and **the host
  downloads the DiB0700 firmware** — the kernel log shows that succeeding **7×** on
  Oct 6/7. The 256-byte EEPROM is a config EEPROM only (blank tail is normal).
* **Why a day was lost:** upstream decides cold/warm with
  `*cold = GET_VERSION() <= 0`. The card was stuck in the ROM-idle state that
  *answers* GET_VERSION (`ram=0x00000001`), so the kernel called it **warm, skipped
  the download**, and failed at `i2c_enumeration`. The proven path had never run.
* **Revival (18:31):** `insmod dvb_usb_dib0700` + staged decompressed firmware +
  **pull ≥ 60 s** → `in cold state` → `firmware started successfully` → frontend +
  xc2028 tuner up. Then unbind and load our module: `/dev/video2`,
  `ram=0x00010200`, `CX25843 chip id = 0x34`, **`analog capture ready` with no
  bring-up warning**.
* **Host gotcha that cost two failures:** NixOS ships firmware as `.fw.zst` and
  `request_firmware()` cannot decompress zstd — that is why `xc3028-v27.fw` and
  `v4l-cx25840.fw` "failed with error -2". Decompress into a dir and add it to
  `/sys/module/firmware_class/parameters/path`.
* **New open item:** after a cold boot the CX25843 ACKs at `0x44` but every read
  returns `0x00`; a **GPIO sweep** (`gpio <n> 1 <0|1>`, n=0..15) makes it answer
  `0x34` and it stays. The causal pin is not isolated — likely a decoder
  power/reset line `board_init` does not drive.
* **Capture is not yet proven again** because **no composite/S-Video source is
  connected** (`0x40e = 0x00`, signal absent → the decoder emits no BT.656 and no
  buffers fill). Connect a source and `0x40e` should read `0x7f`.

**Host left as:** card bound to our `pctv320cx` module, `/dev/video2` present,
bridge firmware running (`ram=0x00010200`), decoder microcode loaded,
`/tmp/pctv-fw` staged + on the `firmware_class` path, in-tree `dvb-usb*` modules
loaded but unbound from the card, no watcher/usbmon running.
