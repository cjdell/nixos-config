# HANDOVER — pctv320cx native driver, on hardware

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
