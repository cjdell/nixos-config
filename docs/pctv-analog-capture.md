# Analog capture on a DVB-only USB bridge — the PCTV 320cx with no kernel code

**Host:** `macbook-pro-2009-nixos` (ExpressCard slot). **Device:** Pinnacle PCTV 320cx,
USB `2304:022e` — DiB0700 USB bridge + DiB7000P demod + CX25843 A/V decoder.
**Live since:** 2026-10-08. **Authority for hardware facts:** `pctv-linux/TRUTH.md`
("§n" below refers to that file).

Composite and S-Video in, MPEG-2 file out, at full 720×576i/25 fps — on a mainline
kernel, with **no out-of-tree module, no kernel patch and no kernel config change**.
This is the brief on how that is possible and what the interesting parts were.

---

## 1. Why it looked like a kernel job

* Upstream `dvb-usb-dib0700` supports this card **as DVB-T only**. It boots the bridge,
  attaches the DiB7000P frontend, registers `/dev/dvb/adapter0` and stops there. It
  never touches the analog path, so there is no `/dev/video*` and nothing for OBS,
  mpv, qv4l2 or `ffmpeg -f v4l2` to open.
* The analog side was Windows-only (Pinnacle's `Ltn_hyd7700pc*.sys`). The Win7
  passthrough route is written up in `docs/pctv-320cx.md` and **failed**: the guest
  driver enumerated everything, issued zero bulk-IN URBs, and bugchecked.
* So the natural next step looked like "write a V4L2 driver". We did —
  `pctv-linux/driver/`, Rust core + C V4L2 glue, and it worked on hardware — and then
  **deleted it from the running config** in favour of userspace. That is the point of
  this document.

## 2. The insight: everything is a control transfer

The DiB0700 exposes its whole personality through **vendor control requests on EP0**,
plus bulk OUT EP1 (firmware download) and bulk IN EP2/EP3 (the stream). The DVB driver
already speaks that protocol; the analog path is *the same protocol with different
parameters*:

| function | request | who else uses it |
| --- | --- | --- |
| firmware download / `JUMPRAM` | bulk OUT `0x01`, then `08 00 00 00 70 00 00 00` (`jumpram → 0x70000000`) | DVB driver (cold boot) |
| `GET_VERSION` | `c4 15 …` → 16 B | DVB driver (cold/warm test) |
| `SET_CLOCK`, `SET_I2C_PARAM`, `SET_GPIO` | `0x0b`, `0x10`, `0x0c` | DVB driver (board init) |
| I²C read/write to any device on the bridge bus | `0x12` / `0x13` (new API) | DVB driver (demod, tuner, EEPROM) |
| **`ENABLE_VIDEO`** — route BT.656 to a bulk-IN endpoint | **`0x0f`** | DVB driver uses mode 1 (TS); analog needs **mode 2** |

Nothing there needs to run in kernel context: the register traffic is a handful of
control transfers at bring-up, and the steady state is one bulk read loop. There is no
timing-critical work below `read()`, no interrupt latency requirement, and no need to
present a `videodev` interface to anyone — the only consumer is our own program.
**libusb gives all of it**, so the "driver" becomes a program.

## 3. How the protocol was reverse-engineered

1. **`usbmon` on the host while the Win7 guest drove the card** (`/dev/usbmon2`,
   parsed by `monparse.py`, captures in `pctv-linux/logs/`). This yielded the exact
   firmware record stream (`extract_fw.py`) and the vendor request sequences.
2. **Ghidra on `Ltn_hyd7700pc_64.sys`** (decompilation + strings in `logs/`), which
   uses the same request set Linux documents in `drivers/media/usb/dvb-usb/dib0700.h`.
3. **Firmware record format**, recovered and checksum-verified:
   `[len][addr_hi][addr_lo][type][data…][chk]`, `chk = -(len+addr_hi+addr_lo+type+Σdata) & 0xff`,
   `type 4` = extended address, `type 1` = EOF. Linux's `dvb-usb-dib0700-1.20.fw` is
   1610 records / 33768 B; the Windows blob (`firmware/win_fw.bin`) is a different ~34 KB.
4. **A dead end worth recording:** an early bus scan found only `0x40` (demod), `0x44`
   and the EEPROM at `0x50`–`0x57`, and nothing at the usual Conexant addresses
   (`0x18/0x1a/0x1c/0x1e`), so the CX2584x strings in the Windows driver were written
   off as a red herring for this board and the demod was assumed to do the ADC. Wrong:
   the **CX25843 is behind the DiB7000P's I²C gate** and uses **16-bit register
   addressing**. Once the gate is opened it answers at 7-bit `0x44` with chip id
   `0x100=0x34 0x101=0x84` (device `0x8434`) — which is also why every read form had to
   be re-derived (`cxr`/`cxw`, `rd2`, `nrd16`, `grd1`).

## 4. The bring-up (`pctv_probe stream <input>`)

```
 1  SET_CLOCK 0xb0 (72 MHz, gp3=1) → SET_I2C_PARAM 100 kHz
 2  board GPIOs, the kernel's stk7700ph order: 6=out low, 9/4/7 high, 10 pulse, 0 high
 3  CX25843: if 0x803 bit4 clear or 0x100 != 0x34 → load v4l-cx25840.fw microcode
 4  input mux 0x103; 0x401 = clear CKILLEN + set INPUT_MODE; 0x420 = 0x80 (sat 1.0×)
 5  std_setup: 0x49f=0x11 (PAL) + the 0x470..0x47f geometry block
 6  decoder parallel output on: 0x115 |= 0x0c, 0x116 |= 0x04
 7  poll 0x40d / 0x40e until bit 5 of 0x40e = SIGNAL PRESENT
 8  DiB7000P: release the shared 8-bit parallel bus (1286=0x0000, 1287=0x0003,
    235=0x0022, 236=1792) so the decoder's bytes reach the bridge FIFO
 9  ENABLE_VIDEO **off** (`0f 00 00 00`), then, after 150 ms, ENABLE_VIDEO
    **mode 2** (`0f 12 01 00`), retried up to 8×
10  prime: read and discard 24 × 64 KiB so the stream starts on a line boundary
11  24 async bulk-IN URBs × 32 KiB on EP `0x82`, written to stdout (O_NONBLOCK)
```

## 5. The facts that cost the days

| fact | why it mattered |
| --- | --- |
| **`ENABLE_VIDEO` mode 2, not mode 1** (`0f 12 01 00`) | Mode 1 (what vendor/kernel use) ships only the active part of each BT.656 line: 15.3 MB/s against the 27 MB/s PAL needs, so the bridge silently drops ~32 % of lines. Every "missing chunks / warped geometry" symptom was this. Mode 2 passes EAV+blanking+SAV+active at ~25.6 MB/s (§6). |
| **Mode 2 is only accepted on an off→on transition** | Arming it straight out of bring-up STALLs with a pipe error and the bridge then emits non-BT.656 garbage. Hence step 9. |
| **The demod must tri-state the parallel bus** | DiB7000P shares the bridge's 8-bit bus with the decoder. The DVB driver never has to care; we must, or nothing reaches the FIFO. The Windows driver does exactly this too. |
| **Colour killer must be cleared** (`0x401` bit 6) | The vendor default leaves CKILLEN set, which pins chroma neutral — composite looked permanently grey while S-Video looked fine. |
| **GPIO1 is the decoder power/reset line** | After some cold boots the CX25843 ACKs at `0x44` but every read returns `0x00`. `gpio 1 1 0; gpio 1 1 1` recovers it and it stays recovered (§6). Found by sweeping GPIO0–15; `board_init` never drives it. |
| **Signal presence is `0x40e` bit 5** (`0x40d & 0xf` = detected std) | With a source: `0x40d=0x94 0x40e=0x7f`. Without: `0x40e=0x00`. This is the "is the cable actually in?" test — and the reason a "no signal" capture is *valid black frames*, not zero bytes. |
| **The ROM's first-downloader rule** (§2.1) | The one thing userspace cannot do. See §7 below. |
| **`rq 0x02` with `wValue 0` wedges the ROM's I²C engine** | `GET_EEPROM` STALLs forever afterwards and **only a physical pull ≥ 60 s clears it** — not a port reset, not `authorized` 0→1. This is what made "probing everything kills the stick" look supernatural (§4). |

## 6. Pixels, and the pipeline around them

`pctv_probe` emits **raw BT.656 on stdout** (diagnostics on stderr), so the stream is
consumable by anything. `pctv-monitor` parses it properly rather than guessing:

* EAV/SAV sync words give exact line boundaries and blanking; the **F bit** delimits
  fields, so interlaced 720×576 comes out correctly without resampling guesswork.
* The `Cb Y Cr Y` quartet is deframed to **UYVY** (829 KB/frame) for both SDL2 and
  ffmpeg.
* Robustness learned the hard way: hold the last good frame instead of showing a
  corrupt one; discard the first field after any stream restart; never let a
  scheduling stall splice two fields across a hole.

`pctv-monitor` (SDL2 + ALSA + ffmpeg, ~2400 lines of C, no dependencies beyond
libusb/SDL2/alsa) then does the parts a capture app needs:

* **MPEG-2 capture** (`c`): deframed UYVY into ffmpeg's stdin, the ALSA PCM into fd 3 →
  720×576 interlaced `mpeg2video` + MP2, a PAL-DVD-style `.mpg`.
* **Encoder fed on a clock, not on arrivals**: every 40 ms the newest complete frame is
  handed over, so video can never run ahead of audio; a frame ring + writer thread
  keeps the display from ever blocking on the encoder.
* **Audio**: selectable ALSA input, live stereo dBFS meter with peak-hold and clip
  count, and a deliberately slow AGC (calibrates the input over ~30 s at 0.5 dB/s,
  it is not a compressor), plus `o` input-monitoring on the speakers.
* **Pipe slack**: 27 MB/s against a 2-core box also running ffmpeg, kwin and SDL means
  the buffer between them matters. The unprivileged `fs.pipe-max-size` default gives
  39 ms of cushion; one hiccup past it discards a whole 32 KiB URB = 19 BT.656 lines.
  The monitor asks for 32 MiB (1.2 s) and `live-module.nix` raises the cap to 64 MiB.

## 7. The one thing userspace cannot do — solved without kernel code

§2.1: the bridge has **no self-booting firmware**; the host must download it, and
**who downloads first after a power-up decides whether it boots at all**.

| first downloader after a real pull | result |
| --- | --- |
| kernel (`dvb_usb_dib0700` binds) | full boot — `registering adapter 0 frontend 0 (DiBcom 7000PC)`, `ram=0x00010200` |
| userspace (`pctv_probe`) | 1610 records written, `jumpram -> ok`, but `ram=0x00000000` — still cold, and the *next* kernel bind only half-boots (`i2c_enumeration failed`). The ROM is poisoned until the next power-cycle. |

So the stock in-tree driver is kept — **as a one-shot ROM bootloader and nothing
else**. `live-module.nix` installs a udev rule for `2304:022e` that starts
`pctv-bridge-handoff.service`, which waits for the firmware search path, `modprobe
dvb_usb_dib0700`, waits for `/dev/dvb/adapter0` (proof of a *full* boot), then writes
the interface to `…/dvb_usb_dib0700/unbind`. The bridge stays warm, interface 0 is
free, and libusb takes over. No module of ours, no patch, no kernel rebuild — a stock
module, a sysfs file and a systemd unit.

## 8. What the NixOS side adds (`pctv-linux/live-module.nix`)

`hardware.pctv320cxLive.enable = true;` → `pctv_probe` + `pctv-monitor` + `.desktop`
entry, the bridge handoff unit and udev rule, `fs.pipe-max-size`, uncompressed
firmware from `libreelec-dvb-firmware` (a userspace downloader cannot read NixOS's
`.fw.zst`), and a pinned WirePlumber profile so the capture *and* playback sinks exist
without anyone touching the desktop audio menu. `noSudo = true` moves the card to
group `video` instead of launching the probe through `sudo -n` — and both binaries are
wrapped so the firmware paths survive `sudo`'s `env_reset`.

## 9. Limits that are still real

* **Audio over the card's USB is undecoded** (§9.6): the only endpoint that ever
  delivers is `0x82`, and it carries BT.656. The pigtail's L/R RCAs must land on a
  host input (line-in), which is what the monitor records.
* **PAL geometry is hard-wired** (720×576); NTSC paths exist in the probe but are not
  the shipped path.
* **Chroma quality** still misses the §14 resampling work — visible as rainbow
  fringing at chroma edges.
* **Never let `pctv-monitor` be the first downloader** after a cold plug (§2.1); and
  after an invalid I²C probe, only a ≥ 60 s pull revives the ROM (§4).

## 10. Where to look

| path | what |
| --- | --- |
| `pctv-linux/TRUTH.md` | **the authority** on hardware behaviour (§2.1 download order, §4 state machine, §6 analog path, §8 retracted claims) |
| `pctv-linux/probe.c` | the userspace driver: vendor request map, `analog2_bringup`, `stream` |
| `pctv-linux/pctv-monitor.c` | BT.656 parser, SDL2 view, MPEG-2 + audio capture, AGC |
| `pctv-linux/live-module.nix`, `package.nix` | deployment: handoff unit, udev, sysctl, firmware, wrappers |
| `pctv-linux/README.md` | usage, keys, options; and why `driver/` (the V4L2 module) is retired |
| `pctv-linux/COLD-BOOT-NOTES.md` | cold-boot runbook and symptom → cause → fix table |
| `docs/pctv-320cx.md` | the superseded Win7-VM route |

**The general lesson:** before writing a kernel driver for a USB device, capture what
the vendor driver actually puts on the wire. If the device is control-transfer + bulk
stream and only one program needs the data, userspace gets you a working product —
faster to iterate, no kernel-version coupling, no `CONFIG_RUST` toolchain, and nothing
to rebuild when the kernel bumps.
