# GROUND TRUTH — Pinnacle PCTV 320cx (DiB0700 + DiB7000P + CX25843)

**This file is the authority.** `FINDINGS.md` and `HANDOVER.md` are a running log
and contain claims that were later disproved; where they disagree with this file,
**this file wins**. Superseded claims are listed explicitly in §8.

Last updated: **2026-10-08 18:50 BST**, host `macbook-pro-2009-nixos`, kernel
**7.2.9**, ExpressCard slot `0000:00:1c.3` (EHCI bus 2, port 3).

---

## 1. Status right now

**The card is alive and fully brought up, and it now has real pictures.** It is
bound to our own driver, exposes a V4L2 node, and on 2026-10-08 ~19:03 a loose
source was wiggled into contact: both **S-Video** and **Composite 1** locked and
25-frame captures produced clean, recognisable frames (an animated character on a
grey/dark background). Captured artifacts (scratch): `/tmp/stable-c1.raw`,
`/tmp/stable-sv.raw`, PNGs `/tmp/stable-{c1,sv}-f10.png`, and the wiggle catches
`/tmp/pctv-WIGGLE-*.png`.

Locked signal seen: `0x40e = 0x7b` (composite1) / `0x7f` (S-Video), `0x40d =
0x84`/`0x94` — matching the Oct 6/7 values. Both were stable over all 25 frames
(Y 16–254 per frame). **The chroma is still wrong:** composite1 is near-greyscale
and S-Video shows heavy rainbow fringing/ghosting, i.e. the §14 chroma/resampling
work is not applied on the V4L2 path (open question 4). Luma is correct.

```
$ sudo ./pctv_probe ver
  hw=0x00000066 rom=0x00000011 ram=0x00010200 fwtype=0x00000000     <- bridge firmware RUNNING
$ sudo ./pctv_probe cxr 0x100 1
  cx 100 = 34                                                       <- CX25843 present (id 0x8434)
$ dmesg
  pctv320cx: DiB0700 bridge microcontroller is running
  pctv320cx: CX25843 chip id (reg 0x100) = 0x34
  pctv320cx: Pinnacle PCTV 320cx analog capture ready               <- no "bring-up incomplete"
  pctv320cx: signal check: 0x40d = 0x91 0x40e = 0x00 -> NO SIGNAL
$ ls /dev/video2
  Pinnacle PCTV 320cx (usb-pctv320cx)
```

`0x40e` bit 5 (`0x20`) = "video signal present". It is clear: **no signal is
locked on the composite/S-Video input.** A source *is* connected (both composite
and S-Video, 2026-10-08) but the connection is loose.

**Correction to an earlier claim:** with no lock the driver does **not** capture
0 bytes. The decoder free-runs and the bridge keeps delivering **valid black
frames** (720×576 UYVY, all pixels Y=16 / Cb=Cr=128) — a 10-frame capture on
2026-10-08 filled 8,294,400 B. So "0 bytes captured" is wrong; the correct
symptom of no signal is *black* frames, and frames only carry a picture once
`0x40e` bit 5 is set.

**Next step to see pictures: get a locked signal.** With a good source `0x40e`
should read `0x7f` (the value measured on Oct 6/7 with a source) and the frames
become a picture instead of black — **this has now been done** (see above).
Because the connectors are loose it may need wiggling while capturing (below).

### Wiggling while capturing

Start a repeated short capture and watch the mean luma byte; black = Y fixed at
16, any picture raises it:

```sh
while :; do
  timeout 15 v4l2-ctl -d /dev/video2 --set-input=0 \
    --stream-mmap --stream-count=2 --stream-to=/tmp/w.raw >/dev/null 2>&1
  od -An -tu1 -v /tmp/w.raw | tr ' ' '\n' | awk 'NF{s+=$1;n++} END{printf "%.1f\n", s/n}'
done
```
Each stream-start also logs `signal check (stream-start): 0x40d = … 0x40e = …`
to dmesg — watch that for `0x40e` bit 5 (`0x20`).

---

## 2. The card's operating model (this is the thing that was misunderstood)

1. **The card has no self-booting firmware.** At every power-up it is *cold* and
   **the host must download the DiB0700 bridge firmware**. Proven by the kernel
   log, which shows this happening successfully **7 times** on Oct 6/7:

   ```
   dvb-usb: found a 'Pinnacle Expresscard 320cx' in cold state, will try to load a firmware
   dvb-usb: downloading firmware from file 'dvb-usb-dib0700-1.20.fw'
   dib0700: firmware started successfully.
   ```

2. **The CX25843 decoder's microcode also lives in RAM** and must be reloaded on
   every boot (`v4l-cx25840.fw`). Both blobs are volatile; a pull loses both.

3. **The external EEPROM is only a 256-byte config EEPROM** — marker byte, VID/PID,
   bcdDevice, string descriptors, model string. It never contained a firmware
   image. Blank past `0x4a` is **normal for it**.

4. So a "revival" is always: **power-cycle → host downloads bridge firmware →
   host loads decoder microcode → capture.** Nothing else.

---

## 3. The recovery procedure that works (proven today, 2026-10-08 18:31)

```sh
cd ~/nixos-config/pctv-linux

# 1. stage the firmware where request_firmware() can find it (see §7: the
#    NixOS .zst files are NOT loadable by the kernel)
mkdir -p /tmp/pctv-fw
cd /run/current-system/firmware
for f in dvb-usb-dib0700-1.20 xc3028-v27 v4l-cx25840; do zstd -dc < $f.fw.zst > /tmp/pctv-fw/$f.fw; done
echo /tmp/pctv-fw | sudo tee /sys/module/firmware_class/parameters/path

# 2. load the in-tree driver (modprobe is blocked by the NixOS blacklist - use insmod)
M=/run/booted-system/kernel-modules/lib/modules/7.2.9/kernel/drivers/media
sudo insmod $M/dvb-core/dvb-core.ko.xz            # + mc.ko.xz, videodev.ko.xz if needed
sudo insmod $M/usb/dvb-usb/dvb-usb.ko.xz
sudo insmod $M/usb/dvb-usb/dvb-usb-dib0700.ko.xz

# 3. PULL the ExpressCard for >= 60 s and re-insert.
#    The kernel must find it COLD (GET_VERSION not answering) - that is the only
#    state from which the download has ever succeeded.
#    Expect: "in cold state" -> "downloading firmware" -> "firmware started successfully"
#            -> "registering adapter" -> frontend + xc2028 tuner

# 4. hand the card to our driver
echo 2-3:1.0 | sudo tee /sys/bus/usb/drivers/dvb_usb_dib0700/unbind
sudo ./build-module.sh                     # builds against the RUNNING kernel
sudo insmod /tmp/pctv-result/lib/modules/7.2.9/updates/pctv320cx.ko.xz
```

The card **stays warm** (firmware running in RAM) across unbind/rebind and module
reload — only a pull or a host power-cycle loses it.

---

## 4. DiB0700 state machine — what is known

| observation | meaning |
| --- | --- |
| `GET_VERSION` (`c4 15 0000 0000`, 16 B) **does not answer** | **cold / true power-on state.** This is what the kernel calls cold and the only state from which a download has worked. |
| `GET_VERSION` answers, `ram=0x00000001` | mask **ROM** idle, no firmware running. `ram` is a **static ROM constant** here — it does *not* change after a download attempt, so "the download was accepted" proves nothing. |
| `GET_VERSION` answers, `ram=0x00010200` | **firmware 1.2.0 running** — the healthy state. |
| `hw=0x66`, `rom=0x11` | constant, all states. |

* Upstream cold detection (`dib0700_core.c:375`): `ret = GET_VERSION(); *cold = ret <= 0;`
  → **a card that answers GET_VERSION is treated as WARM and the kernel will not
  download.** This is why nothing worked for a day: the card was stuck in the
  `ram=0x00000001` ROM-idle state, the kernel called it warm, skipped the
  download, and failed later at `i2c_enumeration`.
* Both recipients work: `bmRequestType` `0xC0` and `0xC4` return the same 16 bytes.
* The two "cold" sub-states are **not deterministic after a pull**: at 18:01 the
  post-pull card answered GET_VERSION (`ram=1`); at 18:31 the post-pull card did
  not answer it (kernel: cold). Which one occurs is not yet characterised.
* ROM-state vendor services (recipient 4, IN): only `0x04` (8 × 00, not a memory
  read — same for all `wValue`/`wIndex` tried), `0x06` (`00 01`), `0x09`, `0x0d`,
  `0x15` (GET_VERSION). Everything else STALLs. **There is no flash read, upload
  or program service in the ROM.**
* **Wedge rule:** `rq 0x02` (I2C-in) with `wValue 0` — and the other invalid
  address bytes — **wedges the ROM's I2C engine**; `GET_EEPROM` then STALLs
  forever while `GET_VERSION` keeps answering. A USB port reset, a usbfs
  `authorized` 0→1 toggle and EHCI resets do **not** clear it. **Only a physical
  pull (≥ 60 s) restores it.** Valid address bytes (`0x01a0`, `0x02a0`, `0x01a1`,
  `0x0180`) are safe. This is the mechanism behind the old "probing every request
  number wedges the stick" note.

## 5. The config EEPROM — complete facts

* Access: `bmRequestType 0xC4`, `bRequest 0x02`, `wValue 0x01a0` (low byte = I2C
  address byte, `0xa0` = EEPROM at 0x50), 8 bytes per transaction.
* **Index law (measured at 12 points + wrap):** the 8 bytes returned are a sliding
  window starting at EEPROM byte **`wIndex >> 8`**. The ROM's index register is the
  **high byte** of `wIndex`, it is **8 bits** wide, and it **wraps**
  (`wIndex=0xff00` → byte 255 then byte 0 again).
* **Second form:** `wValue 0x02a0` = same 8-bit index, **+1 offset, no wrap**
  (`ix=0x0000`→byte 1, `0x1000`→byte 16, `0xff00`→**byte 256**).
  `0x03a0/0x04a0/0x08a0/0x10a0/0x20a0` STALL → nothing reaches past ~256 bytes.
* Content (256 B, `logs/eeprom-window-1791478844/eeprom-1791478863.bin`, 32/32
  windows ok; bytes 0..70 byte-identical to the 15:53 reads):

  ```
  000: d0 04 23 2e 02 00 01 05 04 03 09 04 20 03 50 69  |..#......... .Pi|
  010: 6e 6e 61 63 6c 65 20 73 79 73 74 65 6d 16 03 50  |nnacle system..P|
  020: 43 54 56 20 33 32 30 63 78 16 03 30 30 30 30 30  |CTV 320cx..00000|
  030: 30 30 31 30 30 02 03 02 03 1c 06 06 75 30 05 37  |00100.......u0.7|
  040: 30 30 30 50 08 15 02 50 31 01 00 ff ff ff ff ff  |000P...P1.......|
  050..0xff: all ff   (strays: 0x7f = e3, 0x80 = 00, byte 256 = ff)
  ```

  Decoded: `d0` marker (the Windows driver reads it with `c4 02 01a1`, len 1),
  VID `0x2304` / PID `0x022e` LE, bcdDevice `0x0100`, 5 strings, LANGID `0x0409`,
  "Pinnacle system", "PCTV 320cx", "0000000100", two empty strings, model
  **`05 "7700P"`**, then `08 15 02 50 31 01 00` ("P1" + `01 00`).
* **The EEPROM chip is electrically fine** — after a pull it ACKs 32 reads in a
  row and returns a coherent, reproducible block.
* Nothing in this repo ever **writes** the EEPROM. `rq 0x01` is the ROM's I2C
  write (used by the Windows driver); we have never used it.

## 6. Analog (composite / S-Video) path — what is known

* Decoder: **CX25843**, I2C 7-bit `0x44` (8-bit `0x88`), **16-bit register
  addressing**, reached through the bridge's I2C tunnel. Chip id `reg 0x100 = 0x34`,
  `0x101 = 0x84` → device id `0x8434`.
* Signal detect: **`0x40d & 0xf` = detected format, `0x40e` bit 5 (`0x20`) = signal
  present.** With a source: `0x40d = 0x94`, `0x40e = 0x7f`. Without: `0x40e = 0x00/0x08`.
* Bridge arm for analog: **`0f 12 01 00`** (`REQUEST_ENABLE_VIDEO`, mode **2** =
  whole BT.656 lines, ~25.6 MB/s). Mode 1 (`0f 11 …`, what the vendor/kernel use)
  delivers only the active part and cannot sustain PAL; mode 0 routes through the
  TS multiplexer and yields no BT.656. (FINDINGS §11.)
* The DiB7000P shares the bridge's 8-bit parallel bus with the decoder: it must be
  tri-stated or nothing reaches the FIFO — `1286=0x0000, 1287=0x0003, 235=0x0022,
  236=1792` (`demod_release_bus`). The DVB driver never has to do this; the vendor
  Windows driver does.
* Bridge bring-up order that works: `SET_CLOCK 0xb0` (72 MHz, gp3=1) →
  `SET_I2C_PARAM 100` → GPIO `6=1, 9=1, 4=1, 7=1, 10 pulse, 0=1` → decoder
  microcode + registers → release the demod bus.
* **New today, not yet understood:** after a cold boot the decoder ACKs at `0x44`
  but **reads return `0x00`** (chip id `0x00`, `0x40d/0x40e = 0x00`) in *every*
  read form (`cxr`, `rd2`, `nrd16`, `grd1`). A **GPIO sweep** (`gpio <n> 1 <0|1>`
  for n = 0..15) made it start answering `0x34` and it **stayed** answering
  afterwards. The causal GPIO is **not isolated** — candidates are the pins
  `board_init` does not touch (1, 2, 3, 5, 8, 11, 12, 13, 14, 15). Driving
  `GPIO0=0` or `GPIO15=0` made the I2C tunnel return errors.
  **Practical workaround right now:** if the decoder reads `0x00`, run a GPIO
  sweep, then re-probe.
* V4L2 inputs exposed by our driver: `Composite 1`, `Composite 2`, `Composite 3`,
  `S-Video`. Format: 720×576 UYVY, interlaced, bytesperline 1440.

## 7. Host-level facts that cost hours

* **NixOS compresses firmware with zstd and `request_firmware()` cannot decompress
  it.** `/run/current-system/firmware/*.fw.zst` is therefore invisible to the
  kernel. Symptoms seen today: `Direct firmware load for xc3028-v27.fw failed
  with error -2` and `Direct firmware load for v4l-cx25840.fw failed with error
  -2`. Fix: decompress into a directory and add it to the search path:
  `echo /tmp/pctv-fw | sudo tee /sys/module/firmware_class/parameters/path`.
* **The bridge firmware files differ.** Linux 1.20 = **33768 B**
  (`dvb-usb-dib0700-1.20.fw`, the one that works); the Windows blob
  (`firmware/win_fw.bin`) = **34066 B**. The Linux blob sent from userspace while
  the card was in the `ram=0x00000001` state did **not** boot (1610 records,
  `jumpram -> ok`, `ram` unchanged). The kernel's download from the **cold** state
  does boot.
* **Confirmed from true cold on the 2026-10-08 19:25 boot** (COLD-BOOT-NOTES §0):
  userspace download (1610 records + `jumpram -> ok`) leaves `GET_VERSION` at
  `Pipe error`, both in a fresh process and in-process (`pctv_probe init`).
  Separately, the kernel's `cold state → firmware started successfully → warm
  state` log is **not** proof the bridge booted — a bind that then fails with
  `stk7700ph_frontend_attach: i2c_enumeration failed` is a half-boot (seen this
  session). A fully booted bridge is the one that logs
  `registering adapter 0 frontend 0 (DiBcom 7000PC)` and thereafter survives
  unbind (`warm state`, no re-download) — as in `logs/kernrevive-1791480502/`.
* **modprobe is blocked** for `pctv320cx`, `dvb_usb_dib0700` (NixOS
  `install … false` rules, not in `/etc/modprobe.d` — check
  `modprobe --show-config`). Use `insmod` with the `.ko.xz` path.
* **Our module must match the running kernel.** `./build-module.sh` builds against
  the flake's `boot.kernelPackages`; after a kernel bump (7.2.3 → 7.2.9) old store
  builds fail to insert. Result lands at `/tmp/pctv-result/lib/modules/<k>/updates/pctv320cx.ko.xz`.
* **`pctv_probe` steals the interface from our kernel driver.** It calls
  `libusb_detach_kernel_driver(dev, 0)` on open, so running *any* probe sub-command
  (`ver`, `cxr`, …) while `pctv320cx` is bound **destroys `/dev/video2`**. Restore
  with:
  `echo 2-3:1.0 | sudo tee /sys/bus/usb/drivers/pctv320cx/bind`
  Do not interleave probe calls with a capture test.
* `usbmon` is available (`/dev/usbmon2` = bus 2); parse with `./parse.sh`.
* The EHCI controller can be left wedged by a bad detach (`device descriptor
  read/64, error -110`); recovery is unbind/bind of `0000:00:06.0/1` (see
  HANDOVER "Controller recovery").

## 8. Claims that are now RETRACTED (do not repeat these)

| retracted claim | why it is wrong |
| --- | --- |
| **"The card is dead / bricked at the boot-image level."** | Said at ~18:10 today. Wrong. The card came up fully at 18:31 via the kernel's cold-state download and is running now. |
| "The self-boot image in the EEPROM is gone / should be in the EEPROM." | The card has **no** self-boot image; the host always downloads the bridge firmware (7 successful kernel downloads on Oct 6/7). The EEPROM is a 256-byte config EEPROM. |
| "EEPROM blank past `0x4a` is the fault." | Normal for that chip. |
| "The Win7 VM revived the card today." | It did not. The trace shows the Windows driver **downloading the full image and failing identically** (`st=-32` on every post-download EP0 IN). `guest-w7-alive-20261008.txt` is a *VM* liveness probe, not card health. |
| "`ram=0x00000001` means firmware is running / a revival." | It is the mask-ROM constant. Firmware running is `ram=0x00010200`. |
| "The healthy Windows boot proves no download is ever needed." | True but misread: the Oct 6 healthy traces have 0 downloads because the card was **already warm** from an earlier Linux/kernel download, not because it self-boots. |
| "A 16 KiB EEPROM dump was read." | The old `eepromdump` index (`wIndex = offset`) re-read the same byte 32×; it only reached bytes 0..70. Fixed to `wIndex = off<<8`. |
| "Probing every request number wedges the stick (mysterious)." | Mechanism known: `rq 0x02` with `wValue 0` wedges the ROM's **I2C engine**; only a pull clears it. The map probe is now opt-in (`--map`). |

## 9. Open questions

1. **Which GPIO makes the CX25843 answer?** (Sweep works; the pin is unknown.
   Likely a decoder power/reset line the vendor driver drives and `board_init`
   does not.)
2. **Why does the card come up in one of two post-pull ROM states** (GET_VERSION
   answering with `ram=1`, vs not answering at all)? Is one of them the wedge from
   our own invalid I2C probes?
3. Does the **Windows 34066-byte blob** ever boot the card from a true cold state
   (never tested from that state)?
4. Is the **analog path fully good again** (375 frames @ 25 fps, the Oct 6/7
   result) once a source is connected — including the §14 chroma/resampling fixes?
5. Should the host config be changed so this is automatic: decompressed firmware
   dir + `firmware_class` path, and the `pctv320cx` module load order?

## 10. Tools in this directory

| tool | purpose |
| --- | --- |
| `pctv_probe` (`./pctv_probe` for usage) | userspace libusb tool. Key sub-commands: `ver`, `clock`, `i2cparam`, `gpio`, `scan`, `identify`, `cxr`/`cxw`, `rd2`, `nrd16`/`nwr16`, `grd1`/`gwr1`, `video`, `cap`, `analog2`, `regseq`, `fw`, `eepromdump` (fixed index), `romwin`, `eepromwin`, **`stream`** (bring-up + continuous raw BT.656 to stdout — the userspace driver behind `pctv-monitor`) |
| `rom-window.sh` | wrapper for `romwin` / `--eeprom` for `eepromwin`; preflight, artifacts, dmesg capture. Read-only to persistent storage |
| `build.sh` / `build-module.sh` | build the probe / build `pctv320cx.ko` against the running kernel |
| `pctv-monitor.c` / `build-monitor.sh` | **userspace live monitor GUI (SDL2)** — spawns `pctv_probe stream`, deframes BT.656, displays/snapshots/records. No kernel module |
| `analog-try.sh`, `capture-analog.sh`, `clock-tune.sh` | analog bring-up + capture experiments |
| `driver/` | the Rust out-of-tree kernel driver (`package.nix` builds it) |
| `ROM-WINDOW.md` | how to catch ROM/EEPROM windows and interpret them |
| `FINDINGS.md`, `HANDOVER.md` | running log — **read §8 above for what to ignore** |
