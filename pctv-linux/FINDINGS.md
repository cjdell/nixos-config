# PCTV 320cx — native Linux driver research

Companion to `docs/pctv-320cx.md` (the failed Win7-VM attempt). This file is the
record of the **native Linux** investigation. Everything here was measured on the
real hardware on `macbook-pro-2009-nixos`.

---

## HEADLINE RESULT

**The stick already works natively on Linux — for its DVB side.** With the device
in a healthy state, the in-kernel `dvb_usb_dib0700` driver initialises it
completely:

```
dvb-usb: found a 'Pinnacle Expresscard 320cx' in warm state.
dib0700: firmware started successfully.
dvbdev: DVB: registering new adapter (Pinnacle Expresscard 320cx)
usb 2-3: DVB: registering adapter 0 frontend 0 (DiBcom 7000PC)...
xc2028 15-0061: type set to XCeive xc2028/xc3028 tuner
xc2028 15-0061: Loading 80 firmware images from xc3028-v27.fw, type: xc2028 firmware, ver 2.7
Registered IR keymap rc-dib0700-rc5
input: Pinnacle Expresscard 320cx as .../rc/rc0/input22
dvb-usb: Pinnacle Expresscard 320cx successfully initialized and connected.
```

Demod identified over i2c from **userspace** as well (vendor i2c read):
register 768 = `0x01b3` (DiBcom vendor ID), register 769 = `0x4000` (device ID).

**What does *not* exist is any analog (composite / S-Video) support** — on Linux
*or* Windows. No `/dev/video*` node is created for this stick, and the Windows
driver never started streaming either. So the analog path is genuinely new work,
not a missing port of something that already works elsewhere.

---

## Hardware

| Item | Value | Evidence |
| --- | --- | --- |
| USB ID | `2304:022e`, "Pinnacle systems" / "PCTV 320cx", `bInterfaceClass = 0xff` | `lsusb -v` |
| Bridge | DiBcom **DiB0700** | INF `MOD7000` / `Ltn_hyd7700pc.sys` = "DiBcom DIB7700 based Hybrid reference design" |
| Demod | **DiBcom DIB7000P / 7700P** at i2c 7-bit `0x40` | vendor ID `0x01b3`, device ID `0x4000` read live |
| Tuner | **XCeive XC2028/XC3028** at i2c 7-bit `0x61` on the demod's internal master | kernel `xc2028 15-0061` |
| Config EEPROM | i2c 7-bit `0x50`–`0x57` | read live: USB VID/PID + string descriptors + a small config block |
| Analog decoder | **no CX2584x on any i2c bus** — see "Where is the analog decoder?" | `i2cprobe scan` + `i2cprobe wscan` on buses 14-19 |
| Firmware | **self-booted from ROM** — no download needed. `hw=0x66 rom=0x11 ram=0x00010200` (fw 1.2.00) | `REQUEST_GET_VERSION` |
| Endpoints | EP1 OUT bulk (512), EP1 IN **interrupt** (64/interval 10), EP2 IN bulk (512), EP3 IN bulk (512); 1 interface, 1 alt setting | `lsusb -v` |

Kernel support already present: `drivers/media/usb/dvb-usb/dib0700_devices.c`
lists `"Pinnacle Expresscard 320cx"` → `stk7700ph_frontend_attach` +
`stk7700ph_tuner_attach`.

i2c buses the driver creates: `i2c-14` Pinnacle (DiB0700 bus), `i2c-15` DiBX000
tuner, `i2c-16/17/18` DiBX000 GPIO masters (bit-banged, no real devices answer
correctly on them), `i2c-19` DiB7090 tuner interface.

---

## Vendor request API (measured)

From `drivers/media/usb/dvb-usb/dib0700.h`, confirmed against the live device:

| req | name | dir |
| --- | --- | --- |
| `0x00` | `REQUEST_SET_USB_XFER_LEN` (fw ≥ 1.21 only — **not** this fw) | OUT |
| `0x02` | `REQUEST_I2C_READ` (legacy) | IN |
| `0x03` | `REQUEST_I2C_WRITE` (legacy) | OUT |
| `0x04` | `REQUEST_POLL_RC` | IN |
| `0x08` | `REQUEST_JUMPRAM` | bulk OUT ep1 |
| `0x0b` | `REQUEST_SET_CLOCK` | OUT |
| `0x0c` | `REQUEST_SET_GPIO` | OUT |
| `0x0f` | **`REQUEST_ENABLE_VIDEO`** — MPEG2 vs **ANALOG** | OUT |
| `0x10` | `REQUEST_SET_I2C_PARAM` | OUT |
| `0x11` | `REQUEST_SET_RC` | OUT |
| `0x12` | `REQUEST_NEW_I2C_READ` | IN — works |
| `0x13` | `REQUEST_NEW_I2C_WRITE` | OUT — **not implemented by this firmware** |
| `0x15` | `REQUEST_GET_VERSION` | IN |
| `0x06 0x09 0x0a 0x0d 0x0e` | DiBcom extras Linux never uses — prime suspects for analog routing | mixed |

Encodings:
* write: `bRequest = buf[0]`, whole buffer as the data stage.
* read: `wValue = ((txlen-2) << 8) | tx[1]`, `wIndex = tx[2] << 8 | tx[3]`.
* **i2c read needs a register phase.** 2-byte tx (`wValue = addr8|1`, `wIndex = 0`)
  always stalls. Working: 3-byte tx → `wValue = 0x0100|addr8|1`, `wIndex = reg<<8`;
  or 4-byte tx → `wValue = 0x0200|addr8|1`, `wIndex = reghi<<8|reglo` (this is the
  form the DIB7000P needs, since its registers are 16-bit).
* i2c write to the demod: `[0x03, addr8, reghi, reglo, valhi, vallo]` — verified by
  read-back.

`REQUEST_ENABLE_VIDEO` payload (from `dib0700.h`):
```
byte1: 4MSB 1 = enable streaming, 0 = disable ; 4LSB video mode: 0 = MPEG2 188B, 1 = ANALOG
byte2: MPEG2 mode : 4MSB master/slave, 4LSB channel bits
       analog mode: 4MSB 0 = 625 lines, 1 = 525 lines
```
Acceptance is **state-dependent** (the same bytes are accepted or stalled
depending on what was sent before), which makes this request the trickiest one.

---

## The "wedged device" trap (operational, important)

Sending unsupported/invalid vendor requests — probing every request number,
sending `0x13`, or the recipient-0 variants while the firmware is in the wrong
state — puts the stick into a state where **every** transfer stalls, including
`GET_VERSION`. Not recoverable by USB bus reset, rebinding, or re-enumeration:
only a **physical power cycle** (unplug ~20 s) fixes it.

> This trap caused a wrong conclusion earlier in this session. I believed the
> device only accepted `bmRequestType 0xC4/0x44` (recipient 4) and that the Linux
> driver failed because it sends `0xC0/0x40` (recipient 0). **That is false.** On
> a healthy device both recipients work identically — A/B verified back to back:
> `rq 0x15` with `0xC0` → 16 bytes OK; `rq 0x15` with `0xC4` → same 16 bytes OK.
> The recipient-0 stalls were the wedged state, not a protocol mismatch.

Always re-check `sudo ./pctv_probe ver` before trusting any negative result.

---

## What the Windows driver does (usbmon)

* **Freshly power-cycled device:** downloads **no firmware**. Standard
  enumeration, then `c4 02 01a1 0000 0001` → `d0`, `44 0c 0000 0000 0003` data
  `0c 00 80` (SET_GPIO0 output/low), then reads the EEPROM at 0x50 in 8-byte
  chunks (`reg 0x00..0x48`). Then it stops — **it never issues a bulk-IN URB on
  EP2/EP3**, matching the old finding that the analog capture never starts.
* **Wedged device:** downloads 1624 firmware records (34058 bytes) over bulk OUT
  EP1 + `jumpram 0x70000000`, then everything stalls. Blob recovered as
  `firmware/win_fw.bin` (differs from Linux's `dvb-usb-dib0700-1.20.fw`, 1610 records).

Firmware record format (both blobs, checksum verified):
`[len][addr_hi][addr_lo][type][data:len][chk]`,
`chk = -(len + addr_hi + addr_lo + type + sum(data)) & 0xff`,
`type 4` = extended-address record, `type 1` = EOF.

---

## Where is the analog decoder? (settled)

Every i2c bus the device exposes was scanned both ways — by read (`scan`) and by
write (`wscan`, which is the reliable one because a NACK surfaces as an error):

| bus | name | real devices |
| --- | --- | --- |
| 14 | Pinnacle Expresscard 320cx (DiB0700 bus) | `0x40` demod, `0x44`, `0x50`–`0x57` EEPROM |
| 15 | DiBX000 tuner I2C bus | same set as 14 (routed back through the DiB0700) |
| 16 | DiBX000 master GPIO12 | ACKs **all 117** addresses — bit-banged GPIO master, no ACK check, no real device |
| 17 | DiBX000 master GPIO34 | same as 16 |
| 18 | DiBX000 master GPIO67 | same set as 14 |
| 19 | DiB7090 tuner interface | nothing answers |

**There is no CX25840 (or anything at `0x18/0x1a/0x1c/0x1e`) anywhere.** The only
real chips on any bus are the DIB7700P demod and the config EEPROM.

Therefore the "Conexant CX2584x Video/Audio Decoder" strings in
`Ltn_hyd7700pc_64.sys` belong to a *different board variant* handled by the same
driver package (the INF installs both `MOD7000` = the 320cx and `MOD7070P` = the
72e). They are a red herring for this stick.

**Working hypothesis for composite/S-Video on this board:** the DIB7700P is a
*hybrid* demod with its own analog input and internal ADC. Composite/S-Video
enters the demod directly (no RF tuner), is digitised internally, and is routed
out of the demod's parallel/ITU port into the DiB0700 — which is exactly what
`OUTMODE_ANALOG_ADC` (demod reg 1286 = `0x04c0`) selects, and exactly what
`REQUEST_ENABLE_VIDEO` "video mode 1 = Analog" streams. This matches
`docs/pctv-320cx.md` §"Composite capture bypasses the xc3028 RF tuner entirely
(RCA/S-Video is direct ADC)".

What is missing is the **DIB7700P analog baseband configuration** — ADC clock
source, gain/AGC, video detector, sync separator. The Linux `dib7000p.c` never
touches any of it (it implements the DVB-T path only), so this is genuinely new
reverse engineering, and it is the crux of the whole project.

---

## Analog attempt — where it stands

Sequence executed from userspace with the kernel driver unbound
(`analog-attempt.sh`), every demod write verified by read-back:

1. `SET_CLOCK` 72 MHz (`dib0700_set_clock(1,0,1,gp3=1,2,24,0,0x4c)` → `buf[1]=0xb0`)
2. `SET_I2C_PARAM` 100 kHz
3. `DIB7000P_POWER_ALL`: regs 774/775/776/899 = 0, reg 1280 &= 0x1ff → verified `00 00`
4. reg 1287 = `0x0003` ("sram lead in, rdy") → verified
5. **`OUTMODE_ANALOG_ADC`**: reg 1286 = `0x04c0` → verified `04 c0`
6. `REQUEST_ENABLE_VIDEO` = streaming on / **analog** / 625 → accepted
7. bulk IN on EP2, EP3, EP1 → **no data**

Control experiment with `OUTMODE_MPEG2_FIFO` (reg 1286 = `0x0540`, reg 235 |= 6,
reg 236 = 512) + MPEG-mode `ENABLE_VIDEO`: the request **stalled** and no data.

So the bridge accepts the analog streaming request and the demod accepts the
analog-ADC output mode, but nothing reaches USB. The missing piece is almost
certainly the **DIB7700P analog baseband front-end**, which the kernel's
`dib7000p.c` never touches (it is DVB-only): ADC clock source, gain/AGC, video
detector, and whatever the DiBcom-only requests `0x0a` / `0x0e` / `0x06` / `0x0d`
configure on the bridge side.

---

## Tooling (this directory)

| File | Purpose |
| --- | --- |
| `probe.c` | userspace libusb DiB0700 tool — see `--help`. Sub-commands used: `ver clock i2cparam rd2 wr1 raw4 scan3 scanw video cap eeprom probe4 probeout4 gpiosweep videosweep analog watch` |
| `build.sh` | builds `pctv_probe` (nix clang/gcc + libusb1) |
| `analog-attempt.sh` | the demod power-up + `OUTMODE_ANALOG_ADC` + capture sequence |
| `i2cprobe.c` | `I2C_RDWR` scanner/reader for a kernel i2c adapter (works where `i2cdetect` fails with "Bus doesn't support detection commands") |
| `monparse.py` | decodes the **binary** usbmon API. Header is 48 bytes: `id u64, type u8, xfer u8, epnum u8, devnum u8, busnum u16, flag_setup s8, flag_data s8, ts_sec s64, ts_usec s32, status s32, len_urb u32, len_cap u32, setup[8]`, then `len_cap` data bytes |
| `extract_fw.py` | recovers a firmware record stream from a usbmon capture |
| `firmware/win_fw.bin` | firmware the Windows driver downloads (34058 B) |
| `firmware/dvb-usb-dib0700-1.20.fw` | DiBcom reference firmware from linux-firmware |
| `logs/` | raw + parsed usbmon captures, dmesg of the successful kernel init, GPIO/ENABLE_VIDEO sweeps, Ghidra decompilation + strings of `Ltn_hyd7700pc_64.sys` |

## How to reproduce

```sh
# free the device (VM off) and make sure the kernel driver is not holding it
virsh --connect qemu:///system destroy win7
echo 2-3:1.0 | sudo tee /sys/bus/usb/drivers/dvb_usb_dib0700/unbind

./build.sh
sudo ./pctv_probe ver          # expect hw=66 rom=11 ram=10200  (healthy)

# the DVB side, via the in-kernel driver
echo 2-3:1.0 | sudo tee /sys/bus/usb/drivers/dvb_usb_dib0700/bind
sudo dmesg | tail -20          # "successfully initialized and connected"
sudo ./i2cprobe scan 14        # 0x40 demod, 0x44, 0x50-0x57 EEPROM
sudo ./i2cprobe rd2 14 0x40 0x03 0x00 2   # -> 01 b3

# the analog experiment
echo 2-3:1.0 | sudo tee /sys/bus/usb/drivers/dvb_usb_dib0700/unbind
sudo ./pctv_probe ver
./analog-attempt.sh 0x82 8192 /tmp/pctv/analog.raw
```

## Next steps (ranked)

1. **Extract the DIB7700P analog register setup from the Windows driver.**
   `logs/windows-driver-decomp.txt` has 707 decompiled functions. The analog
   object constructor is `FUN_0004ca70` (it names the decoder and issues 3-byte
   i2c writes such as `[00 00 04]` and `[01 30 00]`); the generic i2c wrapper is
   `FUN_00028230`. Trace which registers get written when the analog capture
   filter is built/started, and which of the DiBcom-only bridge requests
   (`0x06 0x09 0x0a 0x0d 0x0e`) are used. This is the only source of the
   proprietary analog sequence — Windows never streamed either, so no
   ground-truth trace exists to capture.
2. **Replay those writes** with `pctv_probe raw4 out 0x03 0x80 <reghi> <reglo> <valhi> <vallo>`
   (verified to work: reg 1286 written as `0x04c0` and read back correctly), then
   `REQUEST_ENABLE_VIDEO` analog, then bulk-IN capture.
3. **Resolve the `ENABLE_VIDEO` state dependence** — the same bytes are accepted
   or stalled depending on prior state. Map the legal transition sequence rather
   than single commands.
4. **Driver shape**: a V4L2-only companion to `dvb_usb_dib0700`, modelled on
   `drivers/media/usb/dvb-usb/cxusb-analog.c` (the closest existing precedent:
   dvb-usb + analog decoder → V4L2). DVB is not needed for the goal.

---

# Session 2 — the Windows capture attempt (2026-10-06, later)

Capturing the Windows driver *while it tries to start a capture* paid off. This
section supersedes several earlier conclusions.

## What was done

`capture.sh analog-attempt 1800` (usbmon on bus 2) + `mark.sh` timeline, then the
guest was driven over ssh (`scripts/pctv-win7-ssh.sh`) so every step is exactly
timestamped:

| step | epoch | what |
| --- | --- | --- |
| VM start, device healthy (no firmware download at boot) | 1791304200 | |
| A: `pctvroute.exe composite` → `ROUTE OK`, crossbar page set to `2: Video Composite In` | 1791304333–340 | |
| B: `mincap.exe` → graph builds, `cap.Run = 0x8007001f`, retries `0x80070016`, `!! no frame` | 1791304351–383 | |

Baseline for diffing: `logs/baseline-windows-boot.parsed` (158 events — Windows
boot with the stick attached issues **only** EEPROM reads + 2 SET_GPIOs; the
driver does nothing until a capture starts).

## Finding 1 — the command channel is bulk OUT EP1, and it is the firmware image

During step B the driver issued **1611 bulk OUT transfers on EP 0x01** (plus 1783
control transfers). Decoded (`extract_bulkout.py`, `extract_full.py`):

- 1606 packets of 21 bytes: `0x10 <LE24 address> <16 data bytes> <checksum>`,
  addresses `0x000000 → 0x006460` — a memory download.
- then `00 00 00 01 ff` = `REQUEST_SET_USB_XFER_LEN` (0x01ff)
- then `08 00 00 00 70 00 00 00` = `REQUEST_JUMPRAM` to 0x70

Byte-for-byte identical to the head of the mainline Linux image
`dvb-usb-dib0700-1.20.fw` (`02 00 00 04 70 00 8a 10 00 00 00 9d e3 bf 98 25 ...`),
and that image likewise ends in `00 00 00 01 ff`. So **Windows downloads its own
DiB0700 firmware at capture start** (`firmware/win_fw.bin`, 34066 B, a different
build from Linux's 33768 B). Earlier "Windows never downloads firmware" was wrong —
it does, just not at boot.

Request numbers (from mainline `dib0700.h`, authoritative):
`SET_USB_XFER_LEN 0x00, I2C_READ 0x02, I2C_WRITE 0x03, POLL_RC 0x04, JUMPRAM 0x08,
SET_CLOCK 0x0B, SET_GPIO 0x0C, ENABLE_VIDEO 0x0F, SET_I2C_PARAM 0x10, SET_RC 0x11,
NEW_I2C_READ 0x12, NEW_I2C_WRITE 0x13, GET_VERSION 0x15`.

## Finding 2 — the complete analog init, captured and replayable

`logs/full-seq.txt` = 1734 operations in exact wire order:
`gpio ×2 → firmware download (1606 bulk) → gpio ×7 → 113 demod register writes
→ SETUP_DEMOD (0x11) payload [11 01 00]`.

`pctv_probe replay logs/full-seq.txt` reproduces it on Linux: **all 1611 bulk OUT
transfers accepted**, 113 writes accepted (1 pipe error), SETUP_DEMOD accepted.
Windows' SETUP_DEMOD payload is `[0x11, 0x01, 0x00]`, not the 4 zero bytes the
Linux driver sends.

The demod is addressed at **two i2c addresses**: 8-bit `0x80` (7-bit 0x40) and
8-bit `0x12` (7-bit 0x09). Windows writes the interface registers (235/236/1285/
1286/1287) to `0x12` and the rest to `0x80`.

## Finding 3 — Windows' analog output mode, decoded against the mainline driver

Windows writes (to 8-bit 0x12): `reg 235 = 0x0022`, `reg 236 = 1792`,
`reg 1286 = 0x0800`. Against `drivers/media/dvb-frontends/dib7000p.c`
`dib7000p_set_output_mode()`:

- `fifo_threshold = 1792` is that function's own default → reg 236 ✓
- `outreg = read(1286) & ~((1<<10)|(0x7<<6)|(1<<1))`, then `|= (1<<10)` unless
  mode is HIGH_Z → **0x0800 = bit 10 set, mode bits 6-8 = 0**, which is exactly
  the `OUTMODE_ANALOG_ADC` / `OUTMODE_DIVERSITY` case (both leave the mode bits 0
  and route via `DIBTX_ON_HOSTBUS`).

So Windows really does select the demod's **analog ADC output path** — confirming
composite/S-Video is digitised inside the DIB7700P. My earlier `1286 = 0x04c0`
was wrong.

## Finding 4 — the gap in Windows' sequence (and it is not enough)

`OUTMODE_ANALOG_ADC` in mainline also requires, via reg **1288**:

```
dib7090_cfg_DibTx(20, 5, 10, 0, 0, 0)   regs 1615=1, 1603=20, 1605=5, 1606=10,
                                        1608=0, 1609=0, 1610=0, 1612=0, 1615=0
dib7090_setDibTxMux(ADC_ON_DIBTX)       reg 1288 |= 1<<7
dib7090_setHostBusMux(DIBTX_ON_HOSTBUS) reg 1288 |= 1<<5
dib7090_enMpegMux(0)                    reg 1287 |= 1<<7
```

**Windows never writes reg 1288 at all** — it enables the host bus but never routes
the ADC onto it. `pctv_probe analogout` adds that step; read-backs confirm it
lands: `1288 = 0x00a0`, `1286 = 0x0800`, `235 = 0x0022`, `236 = 0x0700`
(1287 reads back 0x0003 — bit 7 is not sticky).

## Finding 5 — still zero bytes, everywhere

With firmware loaded, the full Windows init replayed, the 1288 mux completed, and
`ENABLE_VIDEO (0x0f)` accepted, **all three bulk IN endpoints return nothing**:

- `armsweep` tried 10 payload variants (`0f 00/01/02/03/0f/10/11 ...`) × both
  recipients (0 and 4) — every one accepted, zero bytes on EP 0x81/0x82/0x83.
- Endpoint descriptors re-checked: EP1 OUT, EP1/2/3 IN, **all bulk**, wMaxPacketSize
  512, no isochronous. So the pipe choice was never the problem.
- Correcting an earlier claim: the Linux DVB test **never streamed either** —
  every bulk IN completion in `logs/kern-dvb.parsed` is `len_urb=0`
  (`st=-2`/`st=-108`). "The DVB path works" was only ever true for frontend
  *identification*, not for TS data.

## The hard truth

`mincap.exe` fails at `cap.Run = 0x8007001f` — **the Windows driver's analog
capture never worked on this stick either.** So there is no working analog stream
to observe in any OS: the 113-register table is the most complete analog init that
has ever reached this hardware, and it is not sufficient. Everything reachable
from the wire has now been extracted and replayed.

What remains genuinely unknown is the DIB7700P **analog baseband / ADC enable**
(internal gain, video detector, sync separator, ADC clock source) and/or a
DiB0700 firmware request other than `0x0f` for the analog stream. Both need the
DiBcom datasheets or the driver's internal register tables — not the wire.

## Tooling added this session

| file | purpose |
| --- | --- |
| `capture.sh` / `mark.sh` / `parse.sh` | timed usbmon capture + timeline markers + sliced decode |
| `extract_bulkout.py` | pull bulk OUT payloads out of a parsed trace |
| `extract_full.py` | **unified, wire-ordered** script (bulk + control) → `logs/full-seq.txt` |
| `extract_analog_seq.py` | summarise register writes/reads in a time window |
| `pctv_probe replay <seqfile> [arm] [ep] [bytes] [file]` | replay the whole Windows sequence incl. firmware |
| `pctv_probe armsweep <seqfile>` | replay then sweep ENABLE_VIDEO payloads across all IN EPs |
| `pctv_probe analogout [arm] [ep] [bytes] [file] [i2caddr]` | complete the ANALOG_ADC mux (reg 1288) + arm + capture |

## If this is picked up again

1. The device must be re-plugged after experiments that stress it (a wedged stick
   answers nothing and only a physical unplug recovers it).
2. `replay logs/full-seq.txt` then `analogout` is the current best full recipe.
3. The one untried high-value source: the **DIB7700P datasheet** register map for
   the analog video path (DiBcom/Parade), or `Ltn_hyd7700pc_64.sys`'s register
   tables mined further than `FUN_0004ca70`/`FUN_00028230`.
4. Also untried: whether the pigtail was even terminated with a source during the
   tests. An unterminated composite input may not matter, but it is unverified.

---

# Session 3 — mining the driver, then the demod's analog path (2026-10-06, later)

## Driver binary mining: negative

Binaries are in `/tmp/pctv/drv/PCTV 72e 320cx/` (`Ltn_hyd7700pc_64.sys` = the
320cx / MOD7000, 570368 B, dated 2007-10-19; `Ltn_stk7070P_64.sys` = the 72e).

The 113 demod writes are **not** stored as `(reg,val)` tables. Searched the binary
for the observed value runs — the monotonic block at regs 79-89
(`0x1c52 0x1c46 0x1c60 0x1c8d 0x1caa 0x1cd6 0x1d03 0x1d20 0x1d44 0x1d68 0x1d86`),
the reg-900 pair, the reg-908 repeats — in BE and LE, 16- and 32-bit forms: **no
hits**. The `0x508`/`0x506` hits in the Ghidra text are struct offsets, not
registers. So the values are computed by C code; extracting them means decompiling
thousands of functions of a driver whose analog path demonstrably never worked.
Stopped there.

## What mainline DOES contain (the real prize)

Gotcha: the core file is **`dib0700_core.c`** (underscore), not `dib0700-core.c` —
that is why earlier fetches 404'd.

`drivers/media/dvb-frontends/dib7000p.c` has the analog-ADC building blocks the
Windows driver left unfinished:

- `enum dib7000p_power_mode` includes **`DIB7000P_POWER_ANALOG_ADC`** ("dem, cfg,
  iqc, sad, agc" + nud + Dout).
- `dib7000p_set_adc_state()`: for non-SOC7090 the ADC lives in **regs 908/909** —
  `ADC_ON`: `908 &= 0x0fff`, `909 &= 0x0003`; `ADC_OFF`: `908 |= bits 12-14`,
  `909 |= bits 2-5`; `VBG_ENABLE`: `908 &= ~(1<<15)`. (SOC7090 instead uses reg
  1925 with `en_slowAdc`/`reset_sladc`.)
- `dib7090_setDibTxMux(ADC_ON_DIBTX)` → reg 1288 bit 7, plus
  `dib7090_cfg_DibTx(20,5,10,0,0,0)` → regs 1615/1603/1605/1606/1608/1609/1610/1612.
- `dib7090_setHostBusMux(DIBTX_ON_HOSTBUS)` → reg 1288 bit 5.
- `st->version = read(897)`; chip ID = `read(768) == 0x01b3`.

**There is no analog *video* path in mainline at all** — no input select, no video
detector, no sync separator, no gain. Only the ADC and its output mux. That is the
boundary of public knowledge for this chip.

## The demod was found powered down with its ADC off

Live read-backs before any experiment:

| reg | value | meaning |
| --- | --- | --- |
| 897 version | `0x4000` | not SOC7090 → ADC is regs 908/909 |
| 768 chip ID | `0x01b3` | DIB7700P confirmed |
| 774 / 775 / 776 | `0x3fff / 0xffff / 0x0007` | **the all-blocks-powered-OFF defaults** |
| 908 / 909 | `0x3000 / 0x007b` | **the ADC_OFF bit patterns** |
| 1280 | `0x8a00` | interface power bits |

So the state Windows leaves behind is: demod down, ADC off.

## The complete recipe now implemented (`pctv_probe analogout`)

1. `DIB7000P_POWER_ALL`: 774/775/776/899 = 0, 1280 = 0
2. ADC on: 908 = 0x0000 (VBG_ENABLE + ADC_ON), 909 = 0x0003
3. `cfg_DibTx(20,5,10,0,0,0)`: regs 1615=1, 1603=20, 1605=5, 1606=10, 1608/1609/1610/1612=0, 1615=0
4. Mux: 1288 = `0x00a0` (ADC_ON_DIBTX | DIBTX_ON_HOSTBUS), 1287 |= bit 7
5. Output mode: 235 = 0x22, 236 = 1792, 1286 = 0x0800
6. Arm per `dib0700_streaming_ctrl()`: `buf[0]=0x0f`, `buf[1]=(onoff<<4)`,
   `buf[2]=(0x01<<4)|channel_state`, `buf[3]=0` → **`0f 10 11 00`** for EP2
   (the kernel trace actually carried `0f 11 00 00`)
7. Read EP 0x82

All register writes verified by read-back: `774=0000 908=0000 909=0003 1280=0000
1288=00a0`. **Result: still 0 bytes.**

## Other leads closed

- **GPIOs are already correct.** Decoding Windows' 9 SET_GPIO ops with
  `buf[1]=pin bit, buf[2]=(dir<<7)|(val<<6)` gives exactly mainline's
  320cx-specific sequence in `stk7700ph_frontend_attach()`: GPIO6=0 (this is the
  branch mainline takes *only* for `USB_PID_PINNACLE_EXPRESSCARD_320CX`),
  GPIO9=1, GPIO4=1, GPIO7=1, GPIO10=0→1, GPIO0=1. Nothing missing.
- **SET_USB_XFER_LEN is not applicable**: mainline only sends it when
  `fw_version >= 0x10201`; this device reports `ram = 0x010200`.
- **Smooth-block/sync hypothesis**: swept reg 235 ∈ {0x22,0x02,0x00,0x62,0x32} ×
  reg 236 ∈ {1792,512} with the mux set and EP2 armed — all 0 bytes
  (`logs/smo-sweep.txt`).
- `armsweep` with the mainline-derived payloads (`0f101100`, `0f101000`,
  `0f101300`, `0f100100`, `0f111000`, `0f110000`, `0f101110`, `0f101f00`): some
  payloads are NACKed (`Pipe error`) and some accepted — the firmware does validate
  them — but none produces data on EP 0x81/0x82/0x83.

## Where this genuinely stands

Everything that any public source describes is now driven, verified in silicon, and
produces nothing:

| layer | state |
| --- | --- |
| DiB0700 firmware | loaded (Windows' own image, byte-verified shape), JUMPRAM ok |
| board GPIOs | exactly mainline's 320cx sequence |
| demod init | Windows' full 113-register table replayed |
| demod power | POWER_ALL, verified |
| ADC | enabled (908/909), verified |
| ADC→Tx→host-bus mux | 1288 = 0x00a0, verified |
| output mode | 1286/235/236 per `set_output_mode`, verified |
| bridge arm | `0f 10 11 00` per `streaming_ctrl`, accepted |
| **USB data** | **0 bytes** |

The one thing no public source contains is the **DIB7700P analog baseband**: which
physical input feeds the ADC, and its video detector / sync separator / gain.
Without that the ADC may be sampling nothing, and no amount of bridge-side
configuration will produce bytes. Getting that requires the DiBcom DIB7700P/DIB7090P
datasheet register map (or the vendor's Windows source), not the wire and not the
kernel.

Device left healthy and unbound (`ver` ok, demod readable). Replug before the next
session if anything stops answering.

---

# Session 4 — `Pinnacle_TVCenterProSetup_5.4.0.3032.exe` (2026-10-06)

264 MB InstallShield setup, built 2008-09-16, in the repo root. Payload files are
stored **uncompressed**, so everything below was extracted statically — no VM needed.

Extraction recipe (the PE scan had a bug worth remembering: don't advance the
offset before using it):
```
scan for b"MZ" -> validate e_lfanew/PE sig -> size = max(SizeOfRawData+PointerToRawData)
```
96 PE files recovered to `/tmp/pctv/tvcenter/`.

## 1. No newer driver — the drivers are byte-identical

| installer PE | size | md5 vs `/tmp/pctv/drv/PCTV 72e 320cx/` |
| --- | --- | --- |
| `053_0780ae10.pe` | 373888 | = `Ltn_hyd7700pc.sys` |
| `054_078662d4.pe` | 570368 | = `Ltn_hyd7700pc_64.sys` |
| `057_0790560b.pe` | 466048 | = `Ltn_stk7070P.sys` |
| `058_079772ce.pe` | 543232 | = `Ltn_stk7070P_64.sys` |

All four **identical**. So TV Center Pro 5.4 ships the same 2007 drivers — there is
no later driver build with a working analog path. The 320cx is still supported
(`PID_022E` x4, `320cx` x23 in the package).

## 2. The driver refuses to stream unless the device is high-speed

The .sys contains the wide string:

> `Video Streaming Failed. Device needs to be connected to a USB2.0 Hi-Speed port.`

So the driver has an explicit high-speed gate on video streaming. Checked: the host
negotiates the stick at **480M** (`/sys/bus/usb/devices/2-3/speed`) and the VM has a
proper USB 2.0 stack (`ich9-ehci1` + `ich9-uhci1..3`, hostdev on bus 0 port 4). So
this is *probably* not the cause of `cap.Run = 0x8007001f`, but the guest-side
negotiated speed has never actually been read — worth confirming.

## 3. The INF is registry-driven, and the installer has a NEWER INF with a GPIO table

Our 2007 INF's `MOD7000_DEVICE_AddReg` sets: `ProductId=0` (overridden to `0x22E`
by the board-specific `MOD7000.320cx.AddReg`), `MaskDevicePath=1`, the filter names,
`DCode`, `DigitalAmpLimitLevel/Timer`, `AnalogAmpLimitLevel`, `AudioCaptureSupport`,
`FORMATMODE`.

The installer also contains a **newer MOD7000-family INF** (there `DeviceDesc4 =
"Pinnacle PCTV 73e"`, `MaskDevicePath=0`) which adds a value our INF does not have:

```
HKR,,"GpioStateTable",0x00000001, \
   %GPIO_USB%,   %GPIO_FUNC_BOARD_ON%, 1, %GPIO_USB_DIRECTION_OUT%,   %GPIO_VALUE_SET%,  \
   %GPIO_DEMOD%, %GPIO_FUNC_BOARD_ON%, 2, %GPIO_DEMOD_DIRECTION_OUT%, %GPIO_VALUE_RESET%,\
   %GPIO_DEMOD%, %GPIO_FUNC_BOARD_ON%, 4, %GPIO_DEMOD_DIRECTION_OUT%, %GPIO_VALUE_RESET%,\
   %GPIO_DEMOD%, %GPIO_FUNC_BOARD_ON%, 6, %GPIO_DEMOD_DIRECTION_OUT%, %GPIO_VALUE_RESET%
```
with (from its `[Strings]`):
`GPIO_USB=1`, `GPIO_DEMOD=2`, `GPIO_FUNC_BOARD_ON=1`, `GPIO_FUNC_BOARD_OFF=2`,
`GPIO_DEMOD_DIRECTION_IN=1`/`_OUT=0`, `GPIO_USB_DIRECTION_IN=0`/`_OUT=1`,
`GPIO_VALUE_RESET=0`, `GPIO_VALUE_SET=1`.

**Why this matters:** the driver family accepts a *registry-driven* GPIO sequence
with logical pins `GPIO_USB` and `GPIO_DEMOD` and a delay column — i.e. a
**demod reset/power-on ramp** configurable per board. Our 320cx INF supplies no
`GpioStateTable`, so the driver falls back to its built-in sequence (the one we
captured and replayed), and **our replay never pulsed a demod reset line**.

## 4. Dead end closed: `AnlgCaptureDefaultStandard`

The 72e's registry section has `AnlgCaptureDefaultStandard` and the 320cx's does
not — looked like the missing analog config. It is **not referenced by the 320cx
driver at all** (0 hits in `Ltn_hyd7700pc_64.sys`, narrow or UTF-16LE). The driver
reads exactly the values its own INF provides: `ProductId`, `MaskDevicePath`,
`FORMATMODE`, `AnalogAmpLimitLevel`, `AudioCaptureSupport`, `DCode`,
`AnlgCaptureFilterName` (all present as wide strings). No missing registry config.

## 5. Other payload contents (not DiBcom)

`DVXUSBks.inf` + `DVC.exe` + `Marvin.exe` (a USB *Kernel Streaming* analog capture
driver — Pinnacle's DVX line, different hardware), `Pixie.dll`, `HelperDLL.dll`
(1.6 MB), an `AVICAP32.dll`-using app (#091). Only 76 wide strings in the .sys; the
filter names are the only analog-related ones.

## Recommended next experiment (highest value, not yet done)

Install **TV Center Pro itself** in the Win7 VM and attempt composite capture through
the official application, with usbmon running. It is the only software that uses
this driver's own filter set (`PCTV DiB BDA Analog Capture` / `Analog Xbar` /
`Analog TV Audio`) the way it was designed to be used. If it captures, we finally
get a **working** analog stream to copy — and the failure was in our hand-rolled
DirectShow graph, not the hardware. If it also fails, the analog path is confirmed
dead on this board in every software stack.

Secondary cheap test: add a `GpioStateTable` (with a `GPIO_DEMOD` reset pulse) to
`USB\VID_2304&PID_022E\...\Device Parameters` in the guest and see whether the
driver's USB traffic changes.

## 6. Why "just install TV Center Pro" is not the answer (checked)

`docs/pctv-320cx.md` §5.5 already rules it out, and it is consistent with tonight's
capture:

- the analog capture pin is real and negotiates **YUY2 720x576 16 bpp** (PAL),
- the crossbar routes programmatically (`Video Composite In`, hr=0),
- `IMediaControl::Run()` fails (`0x8007001F` / `0x8007048F`),
- usbmon shows the driver uploading firmware + configuring and issuing **zero bulk-IN**,
- and the driver **bugchecks the guest: `0x0000000A` IRQL_NOT_LESS_OR_EQUAL**.

A kernel driver that bugchecks on analog start cannot be rescued by a better client
app. So the installer's value was the *newer INF* (the `GpioStateTable` above), not
the application.

## 7. The one variable that is still genuinely open

§5.5's own framing: *"Either the driver's analog path is broken under QEMU's
`usb-host` passthrough, or it is simply broken for this card."* Nothing tried so far
separates those two, and they imply opposite futures:

| if the cause is | then |
| --- | --- |
| QEMU `usb-host`/EHCI emulation | the driver works on real hardware; a working analog stream exists to copy, and Linux can be finished from it |
| the driver/board itself | the analog path never worked on a 320cx; only the DIB7700P datasheet can revive it on Linux |

Decisive test (needs hardware we don't have attached): run the same driver on
**bare-metal Windows** with the stick in a real port, or try **USB/IP** instead of
`usb-host` passthrough (different virtual host controller, different URB path).
Watch for the 0x0A bugcheck: if it does not bugcheck on real hardware, the QEMU
hypothesis wins.

---

## Session 5 — the demod was never dead: a USB port reset revives it

**The single most important result of the whole investigation.**

1. `dib7000p_identify()` = read reg **768 → 0x01b3** (DiBcom vendor) and reg
   **769 → 0x4000** (device). Mainline's `stk7700ph_frontend_attach` fails at
   exactly this step — and it has failed on *every* bind ever done on this box
   (`dmesg`: `stk7700ph_frontend_attach: state->dib7000p_ops.i2c_enumeration
   failed`). So the assumption carried since session 1 — "the bridge streams
   fine, only the analog baseband is missing" — had **never actually been
   demonstrated**: there was never a frontend, never a tune, never a TS.
2. Added `identify [bus]` to the probe: sweeps candidate I2C addresses, writes
   reg 1287 = 0x0003 (the "sram lead-in, rdy" write mainline does before
   identify) and reads 768/769 with the NEW_I2C API. First run (stick wedged):
   **0x0000 everywhere** — reads never report a NACK, only writes stall EP0,
   which is why `scan`/`scanw` were useless.
3. Added `reset` (libusb_reset_device = USB port reset). Ran it, the device
   re-enumerated, and `identify` then returned:

   ```
   7bit 0x40 (8-bit 0x80): 768=01b3 769=4000   <== DiBcom vendor ID: demod answers here!
   ```

   **The demod is alive.** "Dead demod, needs a replug" was an artifact of the
   wedged state; a port reset (no unplug, no power cycle) clears it.
4. Bound `dvb_usb_dib0700` right after the reset and the driver came up fully:

   ```
   DVB: registering adapter 0 frontend 0 (DiBcom 7000PC)
   xc2028 15-0061: type set to XCeive xc2028/xc3028 tuner
   xc2028 15-0061: Loading 80 firmware images from xc3028-v27.fw, type: xc2028 firmware, ver 2.7
   dvb-usb: Pinnacle Expresscard 320cx successfully initialized and connected.
   ```

   → `/dev/dvb/adapter0/{frontend0,demux0,dvr0,net0}` + `rc rc0` IR. **The
   device works on Linux 7.2.3 with the mainline driver**, provided the port
   reset happens first. `scripts/pctv-recover.sh` automates the whole thing.
5. New `dvbtest` tool (DVB-T tune + TS read). Two API gotchas found:
   - `dvr0` must be opened **O_RDONLY**: `O_RDWR` → `EOPNOTSUPP` unless
     `CONFIG_DVB_MMAP` (dmxdev.c `dvb_dvr_open`).
   - `dvr0` only carries data once a TS-tap feed runs: `DMX_SET_PES_FILTER`
     with `pid = 0x1fff`, `input = DMX_IN_FRONTEND`, `output = DMX_OUT_TS_TAP`,
     then `DMX_START`.
   - Kernel 6.18 headers: DVBv3 params live in `p.u.ofdm.*`, `INVERSION_OFF`
     (not `SPECTRUM_INVERSION_OFF`), `dvb_frontend_info` has
     `frequency_min/max` + `caps` (no `qam`/`system` mask — use `DTV_ENUM_DELSYS`).
6. Tuned OK (`FE_SET_FRONTEND 522000000` accepted, xc2028 loads its DTV8
   SCODE), full UHF sweep **474–754 MHz in 8 MHz steps: no lock anywhere**,
   strength ~33k–42k and snr ~844 essentially constant → **no RF is connected
   to the stick**. `dvr0` delivered 0 bytes, which is expected without a
   lock. The DVB-T streaming baseline therefore still needs an antenna (or any
   RF source) — that is the one physical prerequisite left.

### What the Windows analog trace actually is (re-read with the demod alive)

`logs/analog-seq-windows.txt`: the analog bring-up is a **full register dump
into the demod at 8-bit 0x80** (regs 2,3,4,6,7,…,198 with 16-bit values) plus
regs **235, 236, 1285, 1286, 1287 at 8-bit 0x12**. 1285 is the dib7000p
I2C-address register (`dib7000p_write_word(st, 1285, (new_addr << 2) | 0x2)`)
— the Windows driver re-addresses the demod to 0x12 part-way through. So the
analog pipeline is **inside the DIB7000P/7070P** (it has an analog baseband +
video digitiser; that is why this is a "hybrid" STK7070P design), and the
bridge side is just `REQUEST_ENABLE_VIDEO` (0x0f) — whose kernel comment is
literally *"MPEG2 vs ANALOG streaming"*.

### Next (in order)

1. Plug in an antenna → `scripts/pctv-recover.sh` → `./dvbtest sweep 1` →
   expect a lock on a London/Uxbridge UHF channel → `./dvbtest <freq> 10`
   proves the bulk-IN streaming path end to end. This is the prerequisite for
   every analog claim in this file.
2. With the demod answering, replay the Windows demod register sequence
   (`extract_analog_seq.py` output) through `i2c2`/`idwr`, then
   `video on analog` + `cap` — the analog stream test, now that the demod can
   actually be programmed.
3. Only after (1)/(2): decide whether the analog path is a register-replay
   job or needs a real dib7000p analog driver (the mainline driver implements
   none of the analog baseband).

### Session 5b — the demod can now be fully programmed from Linux

`pctv_probe regseq logs/analog-seq-ordered.txt` replays the Windows analog
bring-up (the extractor's ordered log) with the NEW_I2C API:

```
replay: 108 write(s), 16 read(s), 9 error(s)
  rd 0x81 reg  768 -> 01b3      rd 0x81 reg  908 -> 3000   (matches the write)
  rd 0x81 reg  769 -> 4000      rd 0x81 reg  909 -> 007a   (matches the write)
  rd 0x81 reg 1280 -> 8a00      rd 0x81 reg 1285 -> 0200
```

* every write to 8-bit **0x80** is accepted and reads back with the value the
  Windows driver wrote — the whole analog register set is now under our
  control from Linux;
* the only failures are the accesses to 8-bit **0x12/0x13** (7-bit 0x09), which
  this unit does not answer (Windows' diversity/second-device path), plus
  `rd 0xa1`;
* the Windows reads use the **legacy** 0x02 request with `wValue=(len-2)<<8|addr8`
  and `wIndex = register` — the probe's `rd()` already matches that.

`pctv_probe analogseq` = clock + i2c-param + kernel GPIO bring-up + `regseq` +
`ENABLE_VIDEO` + bulk-IN read. The Windows analog enable is in the trace after
the register dump: `SETUP_DEMOD data=110100`, i.e. **`0f 11 01 00`** (the probe
had been sending `0f 11 00 00`). Results with the demod programmed:

```
ENABLE_VIDEO 11 01 00: ok        -> ep 0x82: 0 bytes, ep 0x83: 0 bytes
ENABLE_VIDEO 11 00 00: ok        -> 0 bytes
ENABLE_VIDEO 11 11 00: Pipe error
ENABLE_VIDEO 10 00 10: Pipe error   (mpeg2 master-mode form - rejected here)
ENABLE_VIDEO 14 00 00: Pipe error
ENABLE_VIDEO 15 01 00: ok        -> 0 bytes
```

**Still zero bytes — and that is now expected, not evidence.** The dib0700
streams whatever the demod puts on the TS/parallel bus; with **no RF connected**
the sweep (474–754 MHz) never locked and the demod has nothing to emit. The
same is true for the DVB-T baseline: `dvr0` returned 0 bytes for the same
reason. Every streaming claim in this file — Windows *and* Linux — rests on
traces/tests taken with an unconnected antenna input.

### Prerequisite for the next session

**Plug any DVB-T antenna (even a metre of wire) into the stick.** Then:

```sh
sudo scripts/pctv-recover.sh          # port reset + bind + verify (works, tested)
sudo pctv-linux/pctv_probe identify 1 # demod answers: 768=01b3 769=4000
sudo pctv-linux/dvbtest sweep 1       # expect a lock on a London/Uxbridge mux
sudo pctv-linux/dvbtest <freq> 10     # the first real bulk-IN/TS proof
```

Only after that is `analogseq`'s zero-byte result meaningful — and if the DVB-T
TS *does* flow, the analog path becomes a pure demod-register problem (the
bridge side is proven working), which is the best possible position: the
Windows register dump is already replayed successfully.

---

## Session 5c — real i2c bus map; the analog baseband is *inside* the demod

New tool `i2cdev.c` (built with plain gcc): talks to the **kernel's** i2c
adapters with `I2C_RDWR`, i.e. the exact path the driver uses. Adapter numbers
while `dvb_usb_dib0700` is bound:

| bus | name | what answers |
| --- | --- | --- |
| 14 | Pinnacle Expresscard 320cx (dib0700 bus) | **0x40** demod, **0x44** ?, 0x50-0x57 EEPROM |
| 15 | DiBX000 tuner I2C bus (gated through the demod) | same set (gate forwards) |
| 16/17 | DiBX000 master GPIO12 / GPIO34 | 0x08-0x0d (the demod's re-addressed range) |
| 18 | DiBX000 master GPIO67 (gated) | same as 14 |
| 19 | DiB7090 tuner interface | nothing |

* `./i2cdev r2 14 0x40 768 2` -> `01 b3` — the demod reads correctly through
  the kernel path.
* The device at **7-bit 0x44** ACKs and uses 16-bit register addressing, but it
  is **not a working CX2584x**: the cx25840 probe reads the device ID from regs
  0x100/0x101 (`device_id = read(0x101)<<8 | read(0x100)`, expect 0x84xx) and
  both read 0x00; reg 0x82/0x83 = 0; writes mostly do not stick (only reg 0x01
  changed, 0x00 -> 0x07). Reads there are unreliable in every mode tried
  (direct, gated via demod reg 1025 = addr7<<9, kernel bus 15/18). Treat 0x44
  as "the bridge ACKs it", not as a decoder.

**The decisive structural finding:** the Windows analog bring-up
(`logs/analog-seq-ordered.txt`, 112 writes) addresses **only the demod** —
8-bit 0x80, and after `wr 1285` re-addressed to 8-bit 0x12. There is *no*
access to any other i2c device anywhere in the analog sequence, even though
`Ltn_stk7070P.sys` contains a full CX2584x video+audio decoder driver
(strings: "Conexant CX2584x Video Decoder", "cx2584x_initialize_registers_auto_detect").
=> on this stick the analog baseband is **inside the DiBcom hybrid demod**
(the STK7070P design), and the Windows register dump *is* the analog bring-up.

Replay fidelity verified by reading the demod back after `regseq`:

```
reg 235 = 0062   reg 236 = 0700 (1792 - same value mainline's set_output_mode uses)
reg 1025 = 0100  (i2c gate closed)      reg 1029 = 03ff   reg 1032 = ffff
reg 1285 = 0200  reg 1286 = 0000  reg 1287 = 0003
201 of the 256 low registers are non-zero -> the dump really landed
```

`dib0700_streaming_ctrl()` decoded (mainline): payload is
`0f (on<<4) ((1<<4)|channel_state) 00` -> MPEG on = **`0f 10 11 00`**;
Windows' analog enable is **`0f 11 01 00`** (bit0 of byte1 = analog, and the
master-mode bit is *not* set). Both were sent; `SET_USB_XFER_LEN` (`xferlen 4`)
too. Result: **0 bytes on EP 0x82 and 0x83.**

Also: no demod register in 0..255 changes between two dumps 2 s apart — no
analog AGC/lock activity is visible even with the user's S-Video connected.

### Honest state of the analog goal

The bulk-IN path has **never delivered a single byte on Linux** (neither for a
DVB-T tune nor for analog), and the Windows traces never show bulk-IN data
either (session 3: TVCenter was at an error screen, no AV session recorded).
So "the bridge streams fine" is still an assumption, not an observation.

### What would unblock this (in priority order)

1. **A Windows usbmon trace of a working analog (AV-input) capture** — start
   TVCenter, switch to its AV/S-Video input, capture for ~30 s while the
   S-Video source plays. Diffing that i2c sequence against our replay shows the
   missing step; the bulk-IN packets in that trace also reveal the analog
   stream format (framing, sample rate, Y/C layout) which is what any V4L2
   driver would have to decode.
2. **Confirm the AV input is physically wired.** The 320cx is an ExpressCard
   stick in a USB carrier; if the carrier does not route the stick's AV
   connector, no analog signal can reach the chip and every test is moot.
3. Only then: decide between (a) a userspace capture tool (regseq + ENABLE_VIDEO
   + bulk-IN + v4l2loopback) and (b) a real V4L2 driver in `dvb-usb/dib0700`
   exposing the analog path as `/dev/videoN`.

## Session 6 (2026-10-06 late) — the other two Windows drivers never touch analog

Full write-up: `docs/pctv-320cx.md` §5.6. Summary of what it changes for the Linux port:

* The TVCenterPro 5.4 installer (`Pinnacle_TVCenterProSetup_5.4.0.3032.exe`, WinRAR SFX →
  `unrar x "[0]"`) contains 15 driver packages. Only `Driver/PCTV 72e/PCTV.inf` claims
  `USB\VID_2304&PID_022E`. Two others are DiB0700 + **cx2584x** hybrids with the same analog
  BDA filter names: `PCTV 200Xe/64 bit/mod7700.sys` (3.12.4.0, WHQL-signed) and
  `PCTV 340e 801e/64 bit/dvb7700all.sys` (2.3.3.28, unsigned).
* Both were installed on the 320cx in the win7 VM (patched INFs in `driver2/`):
  * `mod7700.sys` — device OK, service RUNNING, but DirectShow gets **only** the control
    filter; no capture/tuner/xbar/audio factories. usbmon (`logs/drv2.parsed`) shows the same
    bridge open as the 2007 driver (ID block read at index `0x01a0` →
    `d0 04 23 2e 02 00 01 05`) and **no bulk OUT / no i2c at all**.
  * `dvb7700all.sys` — needed SHA-1 test signing (guest has no KB3033929, so kernel CI
    rejects SHA-256). Then it loads (device OK) but creates **no PCTV filters whatsoever**.
* Consequence for item 1 above ("get a Windows trace of a working analog capture"):
  **there is probably no such trace to get.** No vendor driver for this PID ever puts the
  analog path on the bus in the VM — the 2008 ones omit the analog stack entirely, the 2007 one
  builds it and never routes it (§5.5.3). The i2c sequence we are missing is not observable
  from Windows as-is; it has to come from the driver binaries themselves (cx2584x register
  writes are in `mod7700.sys`/`Ltn_hyd7700pc_64.sys` — `-AUDIO- cx2584x_audio_set_input %d`
  style debug strings are present) or from the Linux side by driving the cx2584x directly.
* New capability worth keeping: arbitrary INFs/driver binaries can now be installed in the
  guest (newdev `UpdateDriverForPlugAndPlayDevices` from an elevated scheduled task in the
  interactive session + auto-clicking the Win7 prompt + SHA-1 test signing). A "patch the
  .sys, watch what it sends over usbmon" experiment is now practical.

### 5.6 Deep dive, round 3 (2026-10-06 late evening) — three clues we had actually missed

Prompt for this round: *"go directly to the demod's baseband input (or to a decoder). And the
demod digitizes it directly."* That hypothesis is **correct**, and the upstream kernel proves it.
Three things in our own setup were wrong or unexamined.

#### Clue 1 — the 320CX is a **dib7000p (SOC3000P)**, not a dib3000mc

`drivers/media/usb/dvb-usb/dib0700_devices.c`: the device-description list that contains
`"Pinnacle Expresscard 320cx"` (line 4573) belongs to the adapter block just above it, whose
frontend attach is **`stk7700ph_frontend_attach`** → **`dvb_attach(dib7000p_attach, ...)`**, with

```c
static struct dib7000p_config stk7700ph_dib7700_xc3028_config = {
        .output_mpeg2_in_188_bytes = 1,
        .tuner_is_baseband         = 1,          /* <-- !!! */
        .agc_config_count = 1,
        .agc = &xc3028_agc_config, .bw = &xc3028_bw_config, ...
};
```

We have been driving the chip with the **dib3000mc** driver/tables (`dib3000mc_default_init`,
`dib3000mc_default_config`, `dib3000mc_setup_dibcom`). DiB3000P-C is in the dib7000p family; its
register space is ~1300 16-bit registers, not the 3000MC's. That alone explains a lot of the
"the Windows values don't match the kernel tables" confusion — we were comparing against the
wrong family.

#### Clue 2 — the kernel special-cases **our exact USB id** to drive **GPIO6 = 0**

```c
if (desc->idVendor  == cpu_to_le16(USB_VID_PINNACLE) &&
    desc->idProduct == cpu_to_le16(USB_PID_PINNACLE_EXPRESSCARD_320CX))
        dib0700_set_gpio(adap->dev, GPIO6, GPIO_OUT, 0);
else
        dib0700_set_gpio(adap->dev, GPIO6, GPIO_OUT, 1);
msleep(20);
dib0700_set_gpio(adap->dev, GPIO9,  GPIO_OUT, 1);
dib0700_set_gpio(adap->dev, GPIO4,  GPIO_OUT, 1);
dib0700_set_gpio(adap->dev, GPIO7,  GPIO_OUT, 1);
dib0700_set_gpio(adap->dev, GPIO10, GPIO_OUT, 0);
msleep(20);
dib0700_set_gpio(adap->dev, GPIO10, GPIO_OUT, 1);   /* 20 ms LOW pulse */
msleep(20);
dib0700_set_gpio(adap->dev, GPIO0,  GPIO_OUT, 1);
msleep(10);
i2c_enumeration(&adap->dev->i2c_adap, 1, 18, &stk7700ph_dib7700_xc3028_config);
fe = ops->init(&adap->dev->i2c_adap, 0x80, &stk7700ph_dib7700_xc3028_config);
```

**Every probe run we have done drives GPIO6 = 1** (it is also 1 in our "restore" sequence). The
kernel drives it **0 for this board and only this board**. Elsewhere in the same file GPIO6 is
annotated `GPIO6 - Power Supply` (line 3595) and `GPIO6 - EN_TUNER` (line 3695), and
`GPIO6 - currently unknown` (line 3434). Note also the **GPIO10 low→high 20 ms pulse**, which our
sequence does not reproduce in that order.

#### Clue 3 — the dib7000p has an explicit **analog/baseband ADC path**

`drivers/media/dvb-frontends/dib7000p.c`:

```c
enum dib7000p_power_mode {
        DIB7000P_POWER_ALL = 0,
        DIB7000P_POWER_ANALOG_ADC,      /* "dem, cfg, iqc, sad, agc" + "nud" + "Dout"
                                           via regs 774 / 776 / 1280 */
        DIB7000P_POWER_INTERFACE_ONLY,
};
```

and in `dib7000p_init()`:

```c
dib7000p_set_bandwidth(state, 8000);
if (state->cfg.tuner_is_baseband)
        dib7000p_write_word(state, 36, 0x0755);   /* baseband input selected */
else
        dib7000p_write_word(state, 36, 0x1f55);
dib7000p_write_tab(state, dib7000p_defaults);
dib7000p_write_word(state, 901, 0x0006);
dib7000p_write_word(state, 902, (3 << 10) | (1 << 6));
dib7000p_write_word(state, 905, 0x2c8e);
dib7000p_set_power_mode(state, DIB7000P_POWER_INTERFACE_ONLY);
```

So the family has (a) a dedicated **baseband input mux** (reg 36 bit field, `0x0755` vs `0x1f55`)
and (b) a **power domain for the analog ADC**. That is exactly the architecture described in the
prompt: the composite/S-Video baseband enters the demod's own analog front end, which digitizes
it. `tuner_is_baseband = 1` on the 320CX means the XC3028 is *not* feeding an IF — the demod's
baseband inputs are used.

#### Also settled this round

* The `0xa0` EEPROM reads in the Windows session are the **USB descriptor EEPROM**
  (`Pinnacle system` / `PCTV 320cx` / serial `0000000100`) — no analog routing data. Closed.
* The Windows "analog" session we decoded is a **cold-start** path (device in I2C-only state,
  `0xa0` NACKing, firmware download on EP1 OUT, then DIBcom init at `0x80`). Our earlier replay
  was done in the **warm** state (DVB state machine already running) — that is a real
  confounder for every replay result so far.
* The Windows table's writes at `0x80…0x90` are the DIBcom **MC (microprocessor) command
  interface** (`MC_CMD` + `MC_ARG1…ARG16`), i.e. firmware-level commands, not plain registers.
* In that captured session the Windows driver **never reads the video endpoint** — the guest's
  capture failed too. We have still never observed a working analog capture on the bus.
* The driver *does* contain **cx2584x** code (`mod7700.sys` / `Ltn_hyd7700pc_64.sys` carry
  `-AUDIO- cx2584x_audio_set_input %d` style strings), so a decoder driver exists in the stack;
  whether a cx2584x is on the 320CX's bus is still unproven (our 1..127 scan saw only 0x09/0x12).

#### Next experiments, in priority order

1. **GPIO6 = 0** + the kernel's exact 320CX GPIO sequence (incl. the GPIO10 pulse), then the
   existing analog attempt. One-line change, highest value-per-effort.
2. Port the **dib7000p** init into `pctv_probe` (dib7000p_defaults + reg 36 = `0x0755` +
   regs 901/902/905 + `POWER_ALL`) instead of the dib3000mc tables, then replay the Windows MC
   table **from a cold device** (firmware download first).
3. Sanity-check the model by binding the **real kernel dib0700** driver and getting DVB-T to
   lock — that validates dib7000p + xc3028 + the GPIO polarities on real hardware, for free.

### 5.7 The demod side is *solved* — and one real bug in our probe (same session)

Quantitative diff of the Windows analog trace (`logs/analog-seq-windows.txt`, 83 register
writes) against the kernel's `dib7000p_defaults[]` + `dib7000p_init()` (script:
`/tmp/pctv-re/dflt.py`):

```
kernel dib7000p_defaults : 47 registers (4..235)
windows writes at 0x80   : 83 registers
MATCH kernel defaults    : 44        <-- regs 2..17, 26, 79..89, ... byte-for-byte
WINDOWS-ONLY (37)        : 2,3,18,19,21,22,23,24, 36, 72,73,74, 236,
                           770,771,772, 774,775,776, 898,899, 900,901,902,903,905,
                           908,909, 1025,1029,1030,1032,1037, 1280,1285,1286,1287
```

* The Windows sequence **is** the standard dib7000p DVB bring-up: `dib7000p_i2c_enumeration()`
  + `dib7000p_init()` + `dib7000p_defaults[]`. E.g. regs 79..89 = `(1<<13)-825-117, …` =
  `1c52 1c46 1c60 1c8d 1caa 1cd6 1d03 1d20 1d4c` — identical to the trace.
* **Enumeration is visible in the trace**: at `0x12` the driver writes `reg 1285 = 0x0202`,
  which is exactly the kernel's `dib7000p_write_word(1285, (new_addr << 2) | 0x2)` with
  `new_addr = (0x40+0)<<1 = 0x80`. **That write moves the demod from I2C 8-bit 0x12 to 0x80.**
  Everything after it is addressed at `0x80` — and the second pass writes `1285 = 0x0200`
  (= `i2c_addr << 2`, the "unforce divstr" step), `1286 = 0x0000` (`OUTMODE_HIGH_Z`),
  `1287 = 0x0003` (sram lead-in/rdy). Confirms our probe must address **0x80** post-enumeration
  (it already defaults to that).
* `reg 36 = 0x0755` in the trace == the kernel's `if (cfg.tuner_is_baseband) write(36, 0x0755)`.
  So the Windows driver, like the kernel, puts the demod in **baseband-input** mode.
* `reg 235 = 0x0022` and `reg 236 = 0x0700` == `set_output_mode()`'s
  `smo_mode = (rd(235)&0x50)|(1<<1)|(1<<5)` and `fifo_threshold = 1792`. Our values were right.
* Chip is **not** a DiB7090: `reg 897` (the kernel's `state->version`) reads `0x4000`, not
  `0x7090`. So there is **no integrated analog video decoder** in this demod — the analog path
  is the raw **baseband ADC** (`DIB7000P_POWER_ANALOG_ADC` domain, reg 36 mux, ADC regs 908/909),
  not a NTSC/PAL decoder. The "decoder" in the user's hypothesis is the ADC.

#### The bug: reg 1286 was set to the wrong output mode

`dib7000p_set_output_mode()` (kernel) is authoritative for reg 1286:

| mode | reg 1286 |
| --- | --- |
| `OUTMODE_ANALOG_ADC` | `(1<<10)|(3<<6)` = **0x04c0** |
| `OUTMODE_DIVERSITY` | `(1<<11)` = **0x0800** |
| `OUTMODE_HIGH_Z` | `0x0000` |

Our `analog_setup()` wrote **0x0800** — i.e. it drove the demod output into **diversity mode**
(the same value the Windows driver uses only transiently during enumeration) instead of the
**ADC → host-bus** path. That is a strong candidate for "ENABLE_VIDEO armed, endpoint stayed
silent" across every attempt.

Fixed in `probe.c`: `analog_outreg` defaults to `0x04c0`, `analog_mc1287` to `0x0003` (the
Windows value; we used `0x0083`), both overridable:

```sh
./pctv_probe analogout <arm-hex> <ep> <bytes> <file> <i2caddr> [r1286] [r1287] [r235] [r236]
./pctv_probe analogout 0f110000 0x83 200000 logs/analog-adc.bin 0x80 0x04c0 0x0003 0x0022 1792
```

#### Other deltas worth A/B testing

| reg | Windows trace | our probe | note |
| --- | --- | --- | --- |
| 908 | `0x3000` | `0x0000` | kernel: `ADC_ON` = `908 &= 0x0fff`, `ADC_OFF` = `908 |= 0x7000`, `VBG_ENABLE` = `908 &= ~(1<<15)`. Windows leaves bits 12-13 set (partially off); ours is full-on. |
| 909 | `0x007a` | `0x0003` | kernel: `ADC_ON` = `909 &= 0x0003`, `ADC_OFF` = `909 |= 0x003c` |
| 1287 | `0x0003` | `0x0083` | bit 7 (`enMpegMux`) extra in ours |
| 1286 | `0x0800`@0x12, `0x0000`@0x80 | was `0x0800` | see bug above |
| 770,771,772 | `ffff,ffff,001f` | never written | power/GPIO-ish |
| 898, 900, 903 | `0003, 9060, 0027` | never written | ADC/AGC config block |
| 1025,1029,1030,1032,1037 | `0100,ffff,0000,ffff,0000` | never written | unknown block |
| 1288 | never written | `0x00a0` | our invention (ADC_ON_DIBTX|DIBTX_ON_HOSTBUS) |
| 1603-1615 | never written | written | our "DibTx config" — unsupported by the trace |

**Methodological gap to close:** every replay so far counted "writes accepted" at the *USB*
level. The DiB0700 firmware returns success on the control URB even when the I2C transaction
NACKs, so `108 writes accepted` proves nothing. The replay must **read back** a written register
(e.g. write `36 = 0x0755`, then `idrd 1 0x40 36`) to prove the demod actually took it.

### 5.8 SOLVED (hardware architecture): the 320CX has a **CX25843 A/V decoder** at I2C 0x88

Found by scanning the demod's tuner-side I2C bus with a raw `I2C_RDWR` tool
(`/tmp/i2craw`, needed because the DiBX000 adapters expose no SMBus — `i2cdetect -r` fails):

```
# i2craw 15 scan            (adapter 15 = "DiBX000 tuner I2C bus", behind the demod's gate)
  ACK 8-bit 0x80 (7-bit 0x40)   <- DiB7000PC demod
  ACK 8-bit 0x88 (7-bit 0x44)   <- ???
  ACK 8-bit 0xa0 (7-bit 0x50)   <- USB descriptor EEPROM
```

Identified with the kernel's own probe recipe (`cx25840_probe()` in
`drivers/media/i2c/cx25840/cx25840-core.c` — 2-byte sub-address + repeated-start read):

```
reg 0x100 = 0x34, reg 0x101 = 0x84   ->  device_id = 0x8434
   (device_id & 0xff00) == 0x8400  ->  CX25840 family, id = CX25840 + ((0x8434>>4)&0xf) = CX25843
   kernel would print: "cx25843-24 found @ 0x88"
reg 0x8d4 = 0x24   (volume reg: exists only on cx2584x, not cx2583x - confirms family)
```

So the analog chain is **COMPOSITE / S-Video -> CX25843 (ITU-R 656 out) -> DIB0700 parallel
input -> bulk IN** — the same architecture as the Hauppauge cxusb cards, i.e. exactly what
`drivers/media/usb/dvb-usb/cxusb-analog.c` does. The dib7000p's own ADC is *not* the analog path
(that was the wrong hypothesis; the demod is a plain DiB7000PC, reg 897 = 0x4000, not SOC7090).

This also explains the Windows driver strings: `Conexant CX2584x Video Decoder`,
`Texas Instrument TI5150 Video Decoder`, `Dummy Video Decoder`, and the INF's
`PCTV DiB BDA Analog Capture` pin.

#### The decoder was sitting idle — two things were missing

1. **No firmware.** `reg 0x803 = 0x00` (DL_ENABLE never set) - the CX25843 has an internal CPU
   that must be loaded with `v4l-cx25840.fw` before it decodes anything. Loaded it with a raw-I2C
   port of `cx25840_loadfw()` (`/tmp/cxload`, then `/tmp/cxsetup load`):
   `DL_ADDR counter = 16382 / 16382 -> LOAD OK`.
2. **Output was disabled.** `reg 0x115 = 0x00`, `0x116 = 0x00`. The kernel's `cx25840_s_stream(1)`
   is `0x115 |= 0x0c; 0x116 |= 0x04`. Applied and verified: `0x115=0c 0x116=04`.

Then a full kernel-faithful bring-up (`/tmp/cxsetup`: `input_change()` + `cx25840_std_setup()`
for PAL + `cx25840_video_input()` mux + stream on) works and the chip now auto-detects:

```
# cxsetup 15 0x88 std pal composite7 stream
  input mux reg 0x103 = 0x76, INPUT_MODE = composite
  detected standard: 0x1 (NTSC-M)   [0x40c: 00 91 00 00]
```

(`querystd` = `(read4(0x40c) >> 8) & 0xf`.)

#### Input sweep (all 12 decoder inputs)

`cxsetup 15 0x88 sweep pal` sets each of composite1-8 and svideo1-4 (reg 0x103 mux + reg 0x401
INPUT_MODE) and reads the detected standard. **Every input reports the floating-input default
(NTSC-M, 0x40c byte1 = 0x81/0x91/0xa1)** - i.e. **no video source is connected to the card**.
Same story for RF: the DVB-T sweep (174-858 MHz) shows `status=0x01 SIGNAL` only, flat
signal-strength ~42000, no carrier anywhere -> **no antenna**.

#### Also proven this round

- Mainline `dvb-usb-dib0700` **fully drives this card on real hardware**: attaches
  `DiBcom 7000PC` + `xc2028/xc3028` (loads 80 firmware images), tuner bus at `15-0061`,
  GPIO sequence works, `dib7000p_i2c_enumeration` succeeds. The kernel's own streaming arm
  (`0f 10 11 00`) succeeds; the earlier "error while enabling fifo" was a stale-state artifact.
- With the demod forced to `POWER_ALL` + `OUTMODE_MPEG2_PAR_CONT_CLK` (235=0x22, 236=1792,
  1286=0x0440) while the kernel streams, `dvr0` still yields 0 bytes - consistent with **no RF
  signal**, not a broken path. Not yet proven either way; needs an antenna.
- `SET_USB_XFER_LEN` (rq 0x00) is **rejected** by the built-in firmware (1.20.0) - matches the
  kernel's `if (st->state->firmware_version < 0x01010000) return 0;` skip.
- The built-in DIB0700 firmware and the Windows-downloaded one are **different images**
  (1610 vs 1624 records, 48 differing at matching addresses) - a possible confounder, but the
  kernel's own arm works, so it is not the current blocker.
- Our probe's arm payload had a byte-order bug: the kernel sends `0f 10 11 00`, we sent
  `0f 11 00 00`. Both are accepted by the firmware; the kernel's is the correct one.

#### Tools built (all raw-I2C over the dib0700 tunnel, no kernel patch needed)

| tool | purpose |
| --- | --- |
| `/tmp/i2craw.c` | raw `I2C_RDWR` read/write/scan for adapters without SMBus |
| `/tmp/cxload.c` | `cx25840_loadfw()` port - uploads `v4l-cx25840.fw` |
| `/tmp/cxsetup.c` | full CX25843 bring-up: `input_change`, `std_setup` (PAL/NTSC), input mux (composite/s-video), `s_stream`, `querystd` detect, input sweep |
| `/tmp/zap.c` | DVBv3 tune + `dvr0` read + full DVB-T band sweep with status/signal/snr |

#### What is needed next (physical, not software)

1. **Connect a video source** (DVD/STB/game console) to the card's composite or S-Video jack.
   Then `cxsetup ... sweep` will show a real PAL/SECAM detection on the wired input, and we can
   start capturing 656 data through the bridge.
2. **Connect an antenna** to run the DVB-T control test, which proves whether the
   DIB0700 -> bulk-IN streaming path works at all on this hardware.

#### Driver plan (now unambiguous)

Model it on `cxusb-analog.c`: in `dib0700_devices.c` for `PINNACLE_EXPRESSCARD_320CX`,
after frontend attach, get the tuner-side master adapter
(`state->dib7000p_ops.get_i2c_master(fe, I2C_ALGOBIT | I2C_CLASS_TV_DIGITAL, 0)`), instantiate a
`cx25840` i2c client at 7-bit **0x44**, load `v4l-cx25840.fw`, then register a V4L2 device
(`/dev/videoN`) fed from the bridge's bulk-IN, with `ENABLE_VIDEO` armed in the analog variant.
Everything needed for that is now known except the exact `ENABLE_VIDEO`/video-path payload for
the analog (656) mode - which the Windows driver's BDA analog capture path encodes and which a
working capture session would confirm.

### 5.9 Two corrections that invalidate earlier negative results (same session)

**(a) Our ENABLE_VIDEO payload was invalid all along.**
Payload-acceptance sweep against the built-in firmware (fw 1.20.0):

```
0f 00 10 00: ok      0f 00 11 00: ok      0f 10 10 00: ok      0f 10 11 00: ok
0f 11 00 00: Pipe error   0f 11 10 00: Pipe error   0f 11 11 00: Pipe error
0f 11 01 00: Pipe error   0f 12 00 00: Pipe error   0f 13 00 00: Pipe error
0f 1f 00 00: Pipe error   0f 01 00 00: ok
```

The firmware accepts **exactly** what `dib0700_streaming_ctrl()` sends — `buf[1] = (onoff<<4)|0x00`,
`buf[2] = (master ? 0x10 : 0x00) | channel_state` — i.e. `0f 10 11 00` for stream-on of adapter 0
(EP2) and `0f 00 10 00` for stream-off. Any payload with `buf[1] & 0x0f != 0` is **stalled**.
Our probe's "analog variant" (`0f 11 00 00`, from `cmd_video`'s `(on<<4)|analog`) is not a valid
command for this firmware — so every "armed but silent" result before this point was measuring a
rejected command. The correct arm is accepted; capture is still 0 bytes (see below).

**(b) The CX25843 needs `reg 0x803 |= 0x10` to actually run its firmware.**
`cx25840_initialize()` ends with `and_or(0x803, ~0x10, 0x10)` — that starts the internal
microcontroller. Loading `v4l-cx25840.fw` without it leaves the chip inert. After the full
`cx25840_initialize()` port (`/tmp/cxsetup init`): `0x803 = 0x13` (MCU running).
Also `reg 0x144` ("Select AFE clock pad output source") is `0x10` on this chip out of reset while
the driver sets `0x05` — now set.

### 5.10 The decoder sees NO signal on any input — and the Windows driver drives 4 GPIOs the kernel never touches

The driver's own status readout (`cx25840_log_status()`) gives the definitive test:
**reg `0x40d` & 0xf = detected format, reg `0x40e` bit 5 (0x20) = "video signal present"**.
Sweeping all 12 VIN inputs after a full init (PAL/NTSC std setup + input mux + `s_stream`):

```
composite1..8, svideo1..4  ->  0x40e bit5 = 0  (signal absent) on every one
```

So with video playing on the card's composite and S-Video jacks, **nothing reaches the CX25843's
VIN pins** — the path is gated by something else.

Decoding the Windows analog session's SET_GPIO commands correctly (payload is
`0c <pin> <(dir<<7)|(val<<6)>` — my earlier decode was off by one byte and read the request
number as the pin):

```
bmRT=44  GPIO0  dir=1 val=0     (x3)
bmRT=44  GPIO0  dir=1 val=1
bmRT=40  GPIO8  dir=1 val=0     <-- kernel never touches GPIO8
bmRT=40  GPIO14 dir=1 val=1     <-- kernel never touches GPIO14
bmRT=40  GPIO5  dir=1 val=1     <-- kernel never touches GPIO5
bmRT=40  GPIO10 dir=1 val=1
bmRT=40  GPIO15 dir=1 val=0     <-- kernel never touches GPIO15
bmRT=40  GPIO15 dir=1 val=1     (0->1 pulse: looks like a reset/release)
bmRT=40  GPIO0  dir=1 val=1
```

The mainline 320CX sequence only drives GPIO6=0, GPIO9=1, GPIO4=1, GPIO7=1, GPIO10 pulse, GPIO0=1.
**GPIO5, GPIO8, GPIO14 and the GPIO15 pulse are unexplored and are the prime candidates for the
analog input mux / decoder reset / decoder power.** (Precedent: the cx25840 driver's comment
"Drive GPIO2 direction and values for HVR1700 *where an onboard mux selects the output* of
demodulator vs the 417. Failure to set this results in no DTV." — regs 0x160/0x164 on the decoder.)

Also unexplored: `dib0700_ctrl_clock(dev, 72, clock_out_gp3=1)` is called by
`stk7700p/stk7070p/stk7770p/stk807x/stk809x/stk9090m_frontend_attach` but **not** by
`stk7700ph_frontend_attach` (the 320CX path). Since ENABLE_VIDEO puts the bridge in **master
mode** (the bridge drives the pixel clock), the bridge's clock output may be required for the
analog path. Sending it (`pctv_probe clock`) is accepted but did not produce data on its own.

### 5.11 Hardware incident — card dropped off the bus

Applying the full Windows GPIO sequence (including the GPIO15 0->1 pulse) via
`pctv_probe gpio ...` was followed by `usb 2-3: USB disconnect`. The card is in the ExpressCard
slot; `/sys/bus/pci/slots/5/power` refuses to stay on (reads 0) and `echo 1 > /sys/bus/pci/rescan`
does not bring it back. **Needs a physical reseat / power cycle of the card.**
Lesson: change one GPIO at a time and re-check, rather than replaying the whole sequence blind.

### 5.12 Current best model of what is left

1. The analog front end is a **CX25843 at I2C 8-bit 0x88** behind the demod's I2C gate
   (adapter "DiBX000 tuner I2C bus"), fully bring-up-able with `/tmp/cxsetup`
   (`init` = datasheet startup + firmware upload + MCU start + std setup + input mux + stream on).
2. It currently sees no signal because the board routes the jacks through something we have not
   enabled — most likely **DIB0700 GPIO5 / GPIO8 / GPIO14 / GPIO15** (used by the Windows driver,
   ignored by mainline).
3. Once signal is present, the bridge arm is the kernel's own `0f 10 11 00` (accepted), with
   `SET_CLOCK(72, gp3=1)` possibly required, and the demod held in `OUTMODE_HIGH_Z` (reg 1286 = 0)
   so the decoder owns the parallel bus.

---

# Session 4 — the bridge DOES stream; the analog payload is not video (2026-10-07)

## 4.1 SOLVED: the bridge streams — but only with **master mode OFF**

The kernel's arming payload `0f 10 11 00` (ENABLE_VIDEO, channel 1, **master ON**)
is accepted but yields **0 bytes**, always. The variant that actually produces data:

    0f 10 01 00      ENABLE_VIDEO, channel 1, **streaming master OFF**

gives **hundreds of KB per second** (8 MB captured before the buffer filled; the
probe's ring buffer reports LIBUSB_OVERFLOW, i.e. the port outruns the drain).
Also accepted and producing data: `0f 10 02 00`, `0f 10 03 00`, `0f 10 0f 00`.
Rejected (Pipe error): `0f 10 00 00`, `0f 10 10 00`, `0f 11 xx xx`.

Interpretation: with master ON the bridge drives the parallel clock and sees
nothing (FIFO never fills). With master OFF the bridge samples with its own
clock and captures whatever is on the data pins.

## 4.2 The demod inserts the 188-byte TS framing

Captured data is framed: byte 0 of every 188-byte block is **0x47** (42502/42502,
std 0.0). Cause: demod reg **235 bit 5** = `output_mpeg2_in_188_bytes`
(`dib7000p_set_output_mode()`), which our config had set (`235 = 0x0022`).
Clearing it (`PCTV_235=0x0002`) removes the framing.

## 4.3 The payload is NOT BT.656 and NOT a sampled analog waveform

Payload structure: a strict **5-byte period** `80 80 v v v` (the three `v` are
usually identical), ~48% 0x80, values slowly drifting. Verified negative:

* **no valid 656 SAV/EAV words** (`80 1x 2x 3x`) at bit offset 0-7, nor after
  TS-header stripping, nor after per-packet decimation (g,keep,drop) for
  (5,4),(5,3),(4,3),(3,2),(6,5),(5,2), nor for global decimation factors
  1.0-1.65 in 0.002 steps. The 662 "hits" in the payload are chance: the bytes
  following them continue the same 5-byte pattern.
* **no line structure at any period**: mean-profile tip depth 1.4-2.7 (of 255)
  and column-wise adjacent-line correlation <= 0.11 for every period 420-560;
  autocorrelation peaks (1122/1309/1496/1683/1870/2057) are all multiples of the
  187-byte payload, and the 490-556 "fundamentals" are 5-byte harmonics.
* the earlier "period 188" was the TS framing itself, not a video line.

The data **is** content-correlated: a bright scene gives values ~0xb5-0xbf, a dark
scene ~0x2a-0x32, and two captures 3 s apart differ (23.5% identical bytes). So the
decoder's output does reach the data pins — but with no byte alignment to the 656
words and no preserved line timing.

Control experiment: clearing the decoder's video-output enables
(`0x115 &= ~0x0c`, `0x116 &= ~0x04`) still yields data of the same character
(frac80 0.476 vs 0.480) but different values — so the port is not simply idle.

## 4.4 Our decoder config is identical to the vendor driver's

Read the chips after Windows had the device (`pctv_probe cxdump`, read-only — the
chips keep their state across a USB hand-back):

    0x404=31 0x405=25 0x406=10   (BT.656, 8-bit, ANC on, taskbit 1)
    0x470=84 0x472=2d 0x473=5d 0x477=26 0x47c-47e=63 82 0a (sc=688739)
    0x40d=84 (PAL-BDGHI)  0x40e=7f (signal present)
    0x160=00 0x164=00     (VPO pins are NOT claimed by GPIO)

Byte-for-byte the same as what our `analog2` programs, and equal to the driver's
"datasheet video output defaults" (`cx25840_init()`). Windows had the decoder
locked on composite too.

## 4.5 The vendor driver never arms the analog path

The captured Windows analog sequence (`logs/analog-seq-windows.txt`, 1783 control
events) contains **no `0x0f` (ENABLE_VIDEO) at all**; it ends with demod writes
`1280=0000 1285=0200 1286=0000 1287=0003`. That matches its failure
(`cap.Run = 0x8007001f`, retries `0x80070016`, no frame). So Windows offers no
extra recipe — we are at parity with, and ahead of, the vendor driver.

## 4.6 New tooling (all in `probe.c`, single process — no bind/unbind race)

* `analog2 <input> <pal|ntsc> [arm] [ep] [bytes] [file] [r1286] [fw] [gpio:val,..]`
  board init -> `cx_init()` incl. **CX25843 firmware upload over the raw tunnel**
  (46-byte bursts, counter 16382/16382 OK, `0x803=13`) -> input mux -> `std_setup`
  -> lock poll -> demod config -> arm -> capture.
* `cxdump` — read-only dump of CX25843 + demod registers (for comparing against
  another driver's state).
* `dwr <reg> <val> [addr8]` — write one dib7000p word and read it back.
* env knobs: `PCTV_235`, `PCTV_236`, `PCTV_404/405/406`, `PCTV_NOSTREAM`
  (disable decoder output as a control), `PCTV_PREDIV/LOOPDIV/FREEDIV/SCALER`
  (SET_CLOCK; note the PLL has **no** effect on the capture rate — the port is
  clocked by the bus, not the PLL).
* `cmd_cap` now loops 400 x 64 KB instead of 20 x whole-buffer (avoids OVERFLOW).

## 4.7 Where this leaves us

Everything on the decoder side is proven working and matches the vendor driver.
The bridge streams. What is missing is **clock/word alignment on the parallel
bus**: the bridge samples the data pins at a rate unrelated to the decoder's
656 byte rate, so no word boundary or line timing survives. Since master-ON
(the only mode where the bridge supplies the clock) yields nothing at all, the
clock line from the CX25843 to the DIB0700 is the prime suspect.

**Highest-value next experiment: prove the bridge end-to-end over DVB-T** (needs
an antenna). The bridge has never been shown to deliver a real TS on this unit.
* DVB-T works -> the bridge and its clocking are fine, and the fault is isolated
  to the CX25843 -> DIB0700 parallel bus (clock line / data lines).
* DVB-T also yields 0 bytes -> the bridge/USB path itself is broken on this unit.

## Session 7 (2026-10-07, on the MacBook Pro 2009 itself) — the bridge streams, the
## analog payload works, and the old "we have video" claim is refuted

Host: `macbook-pro-2009-nixos` (the ExpressCard stick is in its native slot, no VM).
Device `2-3`, bus 2 dev 28/29. All of this is reproducible with the new probe
commands (`arm`, `cap2`, `pwron`, `demodreset`, `diversity`, `dibrx`) and
`./capture-analog.sh`.

### 7.1 Recovery: the device was wedged, and what actually fixes it

At session start every i2c request (`0x13`, `0x12`, `0x02`) returned `Pipe error`
while `GET_VERSION` (0x15) still answered — the classic wedge. `reset`
(libusb_reset_device), unconfigure/reconfigure, and even a full
`drivers/usb/{unbind,bind}` did **not** revive the demod. What did work:

```
echo 2-3:1.0 | sudo tee /sys/bus/usb/drivers/dvb_usb_dib0700/bind     # kernel driver:
                                                                     # fw load + GPIO init
echo 2-3:1.0 | sudo tee /sys/bus/usb/drivers/dvb_usb_dib0700/unbind   # then hand it back
```

After that the demod answers again (`reg 768 = 01b3`, `769 = 4000`). Note the
kernel driver attaches the *bridge* even when the frontend attach fails
(`i2c_enumeration failed` -> "no DVB adapter allocated") — that is harmless and
is the cheapest way to re-run the bridge's power/GPIO init.

Also: the demod's own GPIOs (regs 1029/1030/1032/1037) reset the demod's i2c
interface. `cmd_demodreset` (new) mirrors `dib7000p_demod_reset()` and restores
a dead-looking demod.

### 7.2 NEW: the vendor's analog arm payload works — `0f 11 01 00`

`REQUEST_ENABLE_VIDEO` (`dib0700.h`) is 4 bytes:
`b0=0x0f  b1=(enable<<4)|video_mode  b2=(1<<4)|channel  b3=0`.
`video_mode` bit0 = **1 = analog**, 0 = MPEG2-188. So:

| payload | meaning | result |
| --- | --- | --- |
| `0f 10 01 00` | MPEG, master OFF, ch0 | **streams**, ~19 MB/s |
| `0f 11 01 00` | **analog**, master OFF, ch0 | **streams**, ~15 MB/s |
| `0f 10 11 00` | MPEG, master ON | rejected (`Pipe error`) |

Analog-mode framing: **4-byte header every 1444 bytes** — `ff 00 00 ab`
(0x17/0x00/0xff/0xc7 variants), then 1440 bytes of payload. That is the
"1440 = 2 × 720" layout the STK7070P analog path would use, so the bridge *has*
an analog framing mode and it is live.

**Arm-stuck gotcha (cost me 30 minutes):** after a capture that ends without a
clean disable, every later `ENABLE_VIDEO` is accepted but yields 0 bytes. Fix —
disable each channel individually, then enable:

```
arm 0f000100 ; arm 0f000200 ; arm 0f000400 ; arm 0f000800     # disable ch0..3
arm 0f110100                                                  # then enable
```

`cmd_cap` also used to bail on the first 1500 ms timeout; it now keeps polling
(the FIFO takes a moment to fill). `cap2 <ep> <secs>` is the timed variant and
prints B/s.

### 7.3 What the analog-mode stream contains: nothing but a clock

45 MB of analog-mode data has **2..10 distinct byte values**: `0x80` (49.9 %),
`0x10` (49.4 %), plus the header bytes and a 4-byte marker every ~1436 bytes.
Strict alternation `80 10 80 10 …` — i.e. one data line toggling at exactly
half the sample rate and the rest static. That is a floating bus picking up the
clock, not video.

Decisive negative controls (all done with the analog arm live):

| change | effect on the stream |
| --- | --- |
| decoder input `composite1` → `composite3` → `svideo1` | **none** (identical statistics) |
| CX25843 VPO output off (`0x115=0x80 0x116=0x03`) | **none** |
| CX25843 clock decimation `0x478/0x479` = 273 / 543 / 1167 | rate stays ~14-19 MB/s |
| decoder std PAL ↔ NTSC | rate unchanged |
| demod `1286` over 20 values (HIGH_Z … ANALOG_ADC) | 0 bytes or the same idle pattern |

So the CX25843's 656 output **does not reach the dib0700's parallel bus**, and
the bridge free-runs (~15 MB/s, its own clock) rather than being clocked by the
decoder.

### 7.4 The demod's parallel *input* (diversity + DibStream Rx) — configured, still idle

New commands `diversity` (regs 204/205/207 + `1286=0x0400`, mirroring
`dib7000p_set_diversity_in` + `OUTMODE_DIVERSITY`) and `dibrx` (the
`dib7090_cfg_DibRx` block, regs 1536/1537/1539/1540/1541/1542/1543/1544 with the
1554 apply-strobe). With `dibrx` configured, the MPEG arm that previously
returned **0 bytes** now returns 56 MB — so the Rx block is real and does gate
the host-bus path. Sweeping `P_Kin:P_Kout` over 14 ratios (1:1, 9:5, 27:15, …)
and the sync-word variants (`0x80102030`, size 4/2, syncMode 0/1, insertExtSync)
always yields the same two-value idle pattern. The decoder's stream is not on
the demod's parallel input either.

### 7.5 REFUTED: §4.3's "content-correlated video" was DVB noise

`/tmp/HUGE.bin`, `BIG.bin`, `RATE-1.bin`, `AR-0f100100-0x82.bin` are **100 %
MPEG-TS framed**: byte 0 of every 188-byte packet is `0x47` (measured 1.000),
with PIDs 0/16/17/18/69/70/71/72/128/103 and a PAT (`PID 0, CC 0`) — the
DIB7000P's internal TS with its COFDM chain unlocked. Consequences of that:

* the "184/188-byte period" and "1840-byte line period" are packet artifacts;
* there are **zero** BT.656 `80 1x 2x/bx 3x/bx` sync words in them;
* the "adjacent-line correlation 41.9 vs 56.3 random" is the TS header column
  effect, not video;
* the "5-byte group" model is the 4-byte TS header + payload.

Frames for all of these are in `pctv-linux/frames/` (`img.py` writes raw /
TS-stripped / 1444-block / every-other-byte layouts as PNGs) so the verdict can
be checked by eye. None of them is a picture.

### 7.6 CX25843 state is good — the decoder is not the problem

With the decoder initialised (`cx25840` firmware loaded, `0x803=13`) on
composite: `0x40d = 0x94` (PAL BGH, 625) and `0x40e = 0x7f` (**video signal
present**), `0x115=8c 0x116=07` (VPO on), `0x404=31 0x405=25 0x406=10` (8-bit
multiplexed 656 out). The AV jack *is* wired and the source *is* being decoded.

New gotcha: **dib0700 GPIO15 resets the CX25843.** Writing GPIO15 (the Windows
trace pulses it `0->1`, "bmRT=40 GPIO15 dir=1 val=1") drops the decoder:
`0x803 -> 00`, `0x103/0x115/0x116 -> 00`, and the stream dies until the decoder
is re-initialised. Don't touch GPIO15 during an analog session.

### 7.7 Where this leaves the analog goal

Working, in order: analog signal → CX25843 (locked, PAL, 656 out enabled) →
**[missing link]** → dib0700 parallel bus → EP 0x82 → host. The bridge and its
USB path are proven good (they carry a real 19 MB/s TS from the demod). The
decoder is proven good. What is missing is the CX25843 → bus hop, and no
demod-side mux setting (`1286`), diversity setting, or DibStream Rx ratio brings
it there. Two readings:

1. the CX25843's 656 is wired to the **DIB7700P** parallel port and the vendor
   puts the demod into a forward mode we have not found (the dib0700's own
   request set has no parallel-port config request; the demod's datasheet-level
   Rx registers we can reach do not sample the external clock); or
2. the stick's CX25843 VPO pins are wired to the demod but the demod's parallel
   input is not connected on this PCB revision — consistent with the vendor's
   own Windows analog enable (`0f 11 01 00`, which we now reproduce exactly)
   also never producing a frame (§4.5: `cap.Run = 0x8007001f`).

Cheapest next steps, in order of value:
* **Scope/continuity check on the stick** (the ExpressCard body is openable):
  CX25843 VPO data/clock pins → DIB7700P parallel pins. That settles 1 vs 2 in
  minutes and is the only thing that can.
* `Ltn_hyd7700pc_64.sys` / `mod7700.sys` contain a full cx2584x driver; mining
  their *demod* write sequence around the analog start (they are the only code
  that could contain the missing forward mode) is the software alternative.
* Do **not** re-derive the "content-correlated video" claim — it is dead (§7.5).

### 7.8 New tooling (all in `probe.c`, plus `img.py` / `capture-analog.sh`)

| command | what it does |
| --- | --- |
| `arm <hex>` | send an arbitrary control-OUT payload, e.g. `arm 0f110100` |
| `cap2 <ep> <secs> [file]` | timed capture, prints B/s and read/timeout counts |
| `pwron <all\|off>` | mirror of `dib7000p_set_power_mode(DIB7000P_POWER_ALL)` |
| `demodreset` | mirror of `dib7000p_demod_reset()` (revives a silent demod) |
| `diversity <on\|off> [1286]` | `dib7000p_set_diversity_in` + `OUTMODE_DIVERSITY` |
| `dibrx <Kin> <Kout> [syncmode] [insync] [syncword] [syncsize] [outrate]` | the DibStream Rx block, regs 1536-1554 |
| `PCTV_ARMDELAY=<ms>` | delay between ENABLE_VIDEO and the first bulk read |
| `PCTV_235/236/237`, `PCTV_DIV*` | demod register overrides in `analog2` |
| `img.py <bin> <outdir> [tag]` | PNG frames for 4 candidate layouts (raw / TS / 1444-block / decimated) |
| `capture-analog.sh [input] [secs] [tag]` | the whole sequence: check → bring-up → arm → capture → frames |

### 7.9 The vendor's exact analog bring-up, replayed, yields **zero bytes**

`./vendor-seq.sh` replays `logs/analog-seq-ordered.txt` (112 demod writes, the
`Ltn_stk7070P.sys` analog sequence) verbatim via `regseq`, then arms. Result:
**0 bytes** on EP 0x82 for every follow-up variant tried:

| after the replay | bytes |
| --- | --- |
| arm `0f 11 01 00` (analog) | 0 |
| `pwron all` + ADC (908=0, 909=3, 1288=0x00a0) + arm | 0 |
| + `1286=0x0440` (PAR_CONT_CLK) | 0 |
| + `1286=0x0800` (MPEG2_SERIAL — what the sequence itself sets at step 20) | 0 |
| + `1286=0x04c0` (ANALOG_ADC) | 0 |

because the sequence *ends* by powering the demod down
(`774=16383 775=65535 776=7 1280=35328 899=3`) and re-writing its GPIOs
(`1029=65535 1030=0 1032=65535 1037=0`). Re-powering does not bring the host-bus
path back in that register state. Recovery afterwards is the normal
`analog2` bring-up (verified: stream returns, demod still answers i2c).

That is the Linux reproduction of the vendor's own failure (§4.5:
`cap.Run = 0x8007001f`, no frame): **the 2007 Pinnacle analog bring-up does not
put the analog stream on the USB bus at all.** Our best working configuration
(`0f 11 01 00` + `1286=0x0000`, 15 MB/s of framed idle data) is strictly better
than the vendor's, and still carries no picture — which localises the fault to
the CX25843 -> bus hop (§7.7), not to our register work.

---

# Session 8 (2026-10-07, later) — **IT IS VIDEO.** §7.3/§7.7 were wrong: the
# source was stopped. With the DVD actually playing the analog path is live.

The user pointed out that every §7 capture had been taken while the DVD had
**stopped playing**. Re-running the identical configuration with the disc
running changes everything.

## 8.1 The working analog path

```
sudo ./capture-live.sh composite1 5 live-shot     # bring-up -> arm -> capture -> frames
/tmp/pyn decode.py /tmp/pctv/live-shot.bin frames live-shot --ascii
```

Recipe (this is the whole thing):

1. `analog2 composite1 pal ...` bring-up — CX25843 firmware loaded, std set,
   input mux `0x103=f0`, VPO on (`0x115=8c 0x116=07`). Decoder reports
   `0x40d=0x94` (PAL) and `0x40e=0x7f` (**signal present**).
2. demod `1286 = 0x0000` (OUTMODE_HIGH_Z) — the demod releases the parallel bus,
   so the **CX25843 is the only bus driver**.
3. release all four channels (`arm 0f000100/200/400/800`), then
   **`arm 0f110100`** = `ENABLE_VIDEO`, enable + **analog framing**, slave mode.
4. `cap2 0x82 <secs>` — ~15.2 MB/s on EP 0x82.

## 8.2 What the stream is

* **1444-byte blocks**: `ff 00 00 ab` + **1440 payload bytes** = one video line.
* Payload byte pairs: the **even byte is always `0x80`** (measured 1.0000 over
  52 576 blocks, for every value of `0x401` and `0x404` tried) and the **odd byte
  is the sample**, in exactly the **BT.656 active range `0x10`..`0xEB`**
  (measured min 16, max 242). So the bus carries **8-bit luma only — no chroma**
  (monochrome picture; the chroma bytes are pinned at neutral `0x80`).
* **Line period = 720 samples** (row-to-row difference 3.2 at W=720 vs 27+ at
  any other width; autocorrelation peak 0.936 at 720).
* **Vertical blanking** is detectable as rows that are >90 % idle (`0x10`);
  the field period measures **~209 framed rows**.
* The bridge frames **~10 000–10 500 blocks/s**, i.e. below the source's
  15 625 lines/s, so it **drops roughly a third of the lines** — frames come out
  720 × ~410 instead of 720 × 625. Nothing is smeared within a line; the loss is
  whole lines. Tuning the CX25843 clock decimation (`0x478/0x479`, 8 values)
  does **not** change the framing rate — it is the bridge's own clock.
* Motion is present: same row, consecutive frames, mean |diff| **9.6** vs 3.2
  between adjacent rows.

## 8.3 The input mux is real (this is what §7.3 got wrong)

Same arm, same everything, only the decoder input changed:

| input | `0x40e` | result |
| --- | --- | --- |
| `composite1` | `0x7f` signal present | luma 16..242, 720×~418 frames, motion |
| `svideo1` | `0x7f` signal present | luma 16..226, frames decode (row diff 5.6, worse than composite's 3.2) |
| `composite3` | `0x4a` **no signal** | luma flat at 16 — pure idle, 0 frames |

So the picture follows the decoder's input mux: the source is on **composite1**,
and the CX25843's 656 output **does** reach the dib0700's parallel bus. §7.3's
"the decoder's 656 output does not reach the bus" and §7.7's "missing link" are
**refuted** — with the disc stopped the decoder was still clocking out its
blanking level, which is exactly the `80 10` pattern §7.3 measured, and every
control (VPO off, `0x404`, decimation) genuinely had no effect *on blanking*.

## 8.4 Also re-checked with a live source

* demod-side outputs (`1286` = `0x0440`/`0x04c0`/`0x0540`) with the **MPEG** arm
  now produce non-TS, non-idle data (228/236/87 distinct values, 512-byte
  periodic structure) — that is the DIB7000P's own path, unrelated to the AV
  jack, and it is *not* video (93 % of its 512-byte blocks are byte-identical).
* `0x0540` is 100 % static — pure idle.

## 8.5 Tooling added this session

| file | what it does |
| --- | --- |
| `capture-live.sh [input] [secs] [tag]` | the §8.1 recipe end-to-end, writes `/tmp/pctv/<tag>.bin` + frames |
| `decode.py <bin> <outdir> [tag] [--ascii]` | block de-frame, luma extraction, line/field sync detection, PNG fields+frames, and an ASCII preview you can read in the terminal |
| `geo-tune.sh [input]` | sweeps CX25843 clock decimation and reports line period / row diff / VBI spacing |
| `frames/live-*-field*.png`, `frames/live-*-frame*.png` | 84 decoded frames from composite1 and svideo1 |
| `captures/live-pal-composite1.bin`, `captures/live-svideo1.bin`, `captures/LIVE-analog2.bin` | 12 MB heads of the live raw captures |

## 8.6 What is still missing for a *good* picture

1. **Chroma.** The bus carries luma only. Either the CX25843 is in an 8-bit
   Y-only output mode (every `0x404` value tried gives the same constant `0x80`
   even byte) or the stick only wires 8 data lines. Worth mining the vendor
   `.sys` for its `0x404`/`0x115`/`0x116` writes with a live source — that is the
   only place a 16-bit or 4:2:2 output setting could be hiding.
2. **Dropped lines.** The bridge frames ~10.5k lines/s against a 15.6k line
   source. `REQUEST_SET_USB_XFER_LEN` (rq 0x00, "fw >= 1.21 only" — this card is
   1.2.00, so probably rejected) and the 1444-byte block size are the levers;
   otherwise accept 720×~410 or interpolate the missing lines.
3. **Geometry.** Field period measures ~209 framed rows rather than 312 (PAL) —
   consistent with the dropped-line model, but a real line-rate lock (or
   counting the source's own syncs) would let the frames be re-stretched.

---

# Session 9 (2026-10-07, later) — the frames are real, but they are **sheared ~45°**

User feedback on the §8 frames: *"all the images are skewed at 45 degrees and black
and white, but they are definitely real image captures."* So the capture path works;
the geometry is wrong. This session was spent trying to find and remove the shear.
**Not solved yet.** Everything measured is recorded below, including the
contradiction that makes this hard.

## 9.1 The shear is real and it is in the data, not in the PNG writer

Cropping a decoded field and watching features move confirms it. In a 200×100 crop
(`live-pal-composite1`, rows 2000-2100, columns 200-400) the `-`/`=` region
boundary and the bright `%%%` blob both march **left** as the row index grows —
about **2.2 px per row**.
Over a 418-row frame that is ~900 px, i.e. more than one full width of shear,
which is exactly what reads as "45 degrees".

Quantified two ways, agreeing:

| method | result |
| --- | --- |
| per-row cross-correlation vs the previous row (search ±25) | shift histogram peaks at **1 px/row** (741 of 1200 rows), 264 rows at 0; cumulative shift −2748 px over 1199 rows, linear fit **−2.0 px/row** |
| visual crop (features marching left as the row index grows) | **−2.2 px/row** |

The gradient-orientation histogram of a decoded field also shows the fingerprint:
dominant 90-95° (normal horizontal edges) plus clear secondary peaks at **45-50°**
and **135-140°** — the diagonal smear a shear produces.

## 9.2 ...but every *periodicity* measurement says the line period is exactly 720

This is the contradiction that has blocked the fix:

* global cost `mean|stream[i] − stream[i+P]|` minimised at **P = 720.05**
  (searched 700-745 in 0.25 steps over 2 M samples);
* the same search in **50 local windows** of 40 k samples (~55 lines each) gives
  **719.75-720.50, mean 720.12, std 0.20** — stable, not drifting;
* framing at period P and measuring row-to-row difference `mean|dV|`:
  P=714 → 7.43, 718 → 4.77, 719 → 4.02, **720 → 3.41**, 721 → 3.84, 724 →  6.13.
  A clean minimum at 720.

If the true line period were 718 (which a −2 px/row shear implies, since framing
at 720 with a true period of 718 shears by 2 px/row), then `mean|dV|` at P=718
should be far better than at 720. It is not.

**Working hypothesis (unproven):** the 720 periodicity is an artifact of the
*block framing*, not of the source. The stream is cut into 1444-byte blocks
(4-byte header + 1440 payload), and extracting the odd byte of every pair gives
exactly 720 samples per block — so the extracted stream inherits a 720-sample
skeleton from the framing itself. The autocorrelation and the `mean|dV|` minima
may therefore be measuring our own framing, while the *content* drifts through
it at ~2 px/row. That would explain both observations at once, and it means
**the line period cannot be recovered by autocorrelation on this stream** —
it has to come from the source's own sync, or from the decoder's clock.

## 9.3 Sync-locked framing: attempted, failed, and why

`decode-sync.py` tries to cut each line at the source's own line sync (end of an
idle run, i.e. an `idle → active` edge) and resample each line to 720. It found
only **1480** idle→active edges in 37.8 M samples, with a median spacing of
11 904 — nowhere near one per line.

Cause: the "idle" level is `0x10`, which is **also BT.6 0** — black picture
content is indistinguishable from blanking, so the edge detector cannot use the
level alone. A working version needs the *real* 656 sync words (`80 1x 2x/bx
3x/bx`), and those are **not present** in this stream: the search of
`live-pal-composite1.bin` for `80 1x 2x|ax 3x|bx` returned **0 candidates**.
The CX25843 is emitting the active-video data with its SAV/EAV stripped (or the
bus is 8-bit Y-only with no sync), so there is nothing to lock on.

## 9.4 Decoder clock sweep — the framing never changes

`clock-tune.sh` re-captures after each register change and re-scores
(best framing period, `mean|dV|`, `mean|dH|`, peak luma):

| setting | bestP | mean\|dV\| | mean\|dH\| | luma max |
| --- | --- | --- | --- | --- |
| baseline `0x478/479 = 0x021f` (543), `0x47a/47b = 0x021f` | 720 | 3.84 | 1.49 | 176 |
| `0x478/479 = 0x048f` (1167) | 720 | 3.02 | 1.57 | 180 |
| `0x478/479 = 0x012f` (303) | 720 | 3.93 | 1.97 | 205 |
| `0x478/479 = 0x0111` (273) | 720 | 3.38 | 1.73 | 220 |
| `0x478/479 = 0x011f` (287) | 720 | **2.58** | **1.11** | 220 |
| `0x478/479 = 0x00ff` (255) | 720 | 3.15 | 1.69 | 213 |
| `0x478/479 = 0x005b` (91) | 720 | 2.97 | 1.31 | 233 |
| `0x478/479 = 0x002c` (44) | 720 | 2.85 | 1.34 | 210 |
| `0x478/479 = 0x0016` (22) | 720 | 2.68 | 1.28 | 228 |
| `0x887/0x888 = 0x01/0x00` | 720 | 4.38 | 2.07 | 206 |
| `0x887/0x888 = 0x02/0x00` | 720 | 2.91 | 1.73 | 207 |
| `0x887/0x888 = 0x04/0x00` | 720 | 2.82 | 1.70 | 224 |
| `0x887/0x888 = 0x08/0x00` | 720 | **2.55** | 1.50 | 225 |

The best framing period is **720 for every setting** — the geometry does not
follow the decoder's decimation registers. `0x478/0x479` and `0x887/0x888` do
change contrast/luma and the noise floor, so they are live registers, but they
are not the line-rate control. (Consistent with §8.2: the framing rate is the
bridge's own clock, ~10.0-10.5 k blocks/s.)

## 9.5 Geometry facts to carry forward

* framing: 1444-byte blocks, `ff 00 00 ab` + 1440 payload; even payload byte
  always `0x80`, odd payload byte = luma in `0x10..0xEB` (**Y only, no chroma**)
* framing rate ≈ 10.0-10.5 k blocks/s ⇒ ~1/3 of the source's 15 625 lines/s are
  dropped; a framed field is ~209 rows, a framed frame ~418 rows
* measured shear ≈ **−2 px per framed row**
* measured framed line period = 720 samples, stable to ±0.2 across the capture
* **no SAV/EAV sync words anywhere in the stream** — no way to lock per-line
* `0x40e = 0x7f` (signal present) on composite1 and svideo1, `0x4a` (no signal)
  on composite3; the picture follows the input mux

## 9.6 Next experiments, in the order that will pay off

1. **De-shear by brute force on a single frame.** Capture ~1 s, then for shear
   values −6..+6 px/row (and fractional) rebuild the frame and score it with a
   metric that is *not* the row-to-row difference (which is contaminated by the
   framing skeleton) — e.g. the sharpness of the strongest vertical edges, or
   the variance of the column-sum profile. If one shear value wins clearly, the
   fix is a per-row shift and we are done.
2. **Find the real sync.** The 656 syncs are absent; look for them in the
   *even* byte stream (the even byte is constant `0x80` in the active region —
   if syncs exist they must be there), or try the CX25843 output-format
   registers that select sync insertion (`0x404` bit 6/7, `0x406`, `0x115/0x116`
   combinations) and re-check for `80 1x 2x 3x`.
3. **Mine the vendor driver** (`Ltn_hyd7700pc_64.sys`, `mod7700.sys`,
   `Ltn_stk7070P.sys`) for the cx2584x writes it makes *with a live source* —
   specifically anything touching `0x478-0x47b`, `0x885-0x88a`, `0x404-0x406`,
   and any 16-bit/4:2:2 output selection. That is the only known source of the
   correct clock/geometry settings.
4. **Chroma is still missing** (§8.6): the even byte is pinned at `0x80` for
   every `0x401`/`0x404` value tried. Either an 8-bit Y-only bus or only 8 data
   lines wired.

## 9.7 Files added this session

| file | what it does |
| --- | --- |
| `decode-sync.py` | sync-locked framing attempt (currently fails to find syncs — §9.3) |
| `clock-tune.sh [input]` | sweeps CX25843 clock/decimation registers, scores geometry |
| `capture-live.sh`, `decode.py`, `img.py`, `geo-tune.sh` | unchanged from §8.5 |
| `frames/SYNC-live-*.png` | output of the sync-locked attempt (not good — kept for reference) |

# Session 10 (2026-10-07, MacBook Pro 2009) — **CLEAN PICTURE, AND COLOUR**

Two long-standing "facts" in this file were wrong, and the analog path now
produces a complete, correctly-framed, colour picture. Summary first:

| claim in this file | reality |
| --- | --- |
| "the picture is sheared 45°, geometry is broken" (§8/§9) | **PNG writer bug.** `png_gray()` took a 2-D array and did `data[y*w:(y+1)*w]`, which on a 2-D array slices *rows*; every scan-line after the first got zero bytes and all the pixels piled into line 0. Most decoders read line 0 then garbage → a diagonal smear. The captured luma was clean all along. |
| "the even byte is pinned at 0x80, chroma is missing" (§8.6) | **The colour killer was on.** `0x401` bit 6 is `CKILLEN`; the vendor init leaves `0x401 = 0x60`. Clearing it (`0x401 = 0xC0`) makes Cb/Cr carry real signal. |
| "geometry/clock registers need tuning" | The decoder was always right; the **bridge drops lines** (see below). |

## 10.1 The block header is a BT.656 sync word, not padding

Every 1444-byte block is `FF 00 00 XY` + 1440 payload bytes. `XY` is the
BT.656 SAV/EAV word — `1 F V H P3 P2 P1 P0`:

* bit6 `F` = field (toggles 0/1/0/1)
* bit5 `V` = vertical blanking (1 in the blanking interval)
* bit4 `H` = 0 for SAV
* low nibble = protection bits

Observed values: `0x80` (F0,V0), `0xC7` (F1,V0), `0xAB` (F0,V1), `0xEC`
(F1,V1). This gives **exact** field/blanking segmentation for free — no
guessing at idle rows. `V==0` runs are active fields.

Payload is 4:2:2 `[Cb Y Cr Y] x 360` → 720 luma, 360 Cb, 360 Cr.

## 10.2 Colour: clear CKILLEN

```
sudo ./pctv_probe cxw 0x401 0xc0     # CKILLEN=0 (bit6), CAGCEN=1 (bit7)
sudo ./pctv_probe cxw 0x420 0x80     # saturation (default 64 -> 0x80)
```

With `0x401 = 0x60` (vendor default) the even bytes are *exactly* `0x80` for
every line — grey. With bit 6 cleared they carry signal (Cb std ~9,
neighbour correlation 0.76). `0x420` is chroma gain: `0x80` = 1.0x, `0xF8` ≈
2x (amplifies the chroma noise too). The chroma is real but noticeably
noisier than luma (luma neighbour corr 0.99, chroma 0.76), so a small
chroma box-blur helps.

New probe commands added for this: `pctv_probe cxr <reg> [n]` and
`cxw <reg> <val>` do **2-byte-register** CX25843 access through the demod
i2c gate — the form `cxdump`/`cx_init` use. (`grd1/gwr1` use 1-byte
addressing and silently return garbage here.)

## 10.3 The missing line groups: the bridge stalls in a *regular* pattern

At full 720-px width the bridge moves ~10 000 of the source's 15 625
lines/s (measured exactly: 10 083 lines/s at `0x472=0x2d`). It does **not**
drop lines at random — it delivers **32 lines, drops the next 16, repeats**
(period 48 source lines). Confirmed by row-to-row difference peaks landing at
`p % 32 == const` (120 of 190 peaks at one residue) and by the fact that
inserting exactly 16 interpolated lines per gap restores the field to its
true **290 active lines** (vactive 580 / 2).

This is what produced the "6 stacked slices": 193 captured lines / 32 ≈ 6
gaps per field.

`decode-clean.py` inserts the 16 lines back (linear interpolation across the
gap) before display, which removes the slices completely.

Narrowing the decoder's active width (`0x471/0x472`) raises the captured line
rate (128 px → full 15 552 lines/s, 320 px → 15 072, 384 px → 13 760, 720 px
→ 10 083), i.e. it trades horizontal resolution for vertical completeness,
but it also re-frames the 1444-byte blocks (two SAVs per block) which makes
decoding messier. Gap-filling at full width is the better trade.

`vactive` (`0x475/0x476`) does not help — the decoder *crops* rather than
scales, so lowering it just blanks lines.

## 10.4 What a clean capture now looks like

```sh
P="sudo -n ./pctv_probe"
$P analog2 composite1 pal 0f000000 0x82 100000 /tmp/pctv/prime.bin 0x0000 /tmp/v4l-cx25840.fw
$P dwr 1286 0x0000              # demod HIGH_Z, CX25843 sole bus driver
$P cxw 0x401 0xc0               # CKILLEN off  -> colour
$P cxw 0x420 0x80               # saturation
for x in 0f000100 0f000200 0f000400 0f000800; do $P arm $x; done
$P arm 0f110100                 # ENABLE_VIDEO: analog framing, slave
$P cap2 0x82 3 /tmp/pctv/good.bin

/tmp/pyn decode-clean.py /tmp/pctv/good.bin snapshots out --index 336 --chroma-blur 1
```

## 10.5 Files added

| file | what it does |
| --- | --- |
| `decode-clean.py` | definitive decoder: BT.656 SAV framing, gap fill, colour, optional chroma blur |
| `decode2.py` | first correct decoder (interleave / single-field), superseded by `decode-clean.py` |
| `decode-color.py` | colour decoder via V-bit segmentation (superseded) |
| `decode-field.py` | single-field + experimental de-shear (de-shear is harmful — the shift estimate accumulates wrong; kept for reference) |
| `color-test.sh` | register sweep harness (uses `cxr`/`cxw` now) |
| `snapshots/` | verification stills |
| fixes | `decode.py`, `img.py`, `decode-sync.py` `png_gray()` now accept 1-D *or* 2-D input |

## 10.6 Still open

* **Chroma SNR.** Real colour is present but noisy; luma is clean. Worth
  trying the chroma bandpass / comb (`0x47b`, currently `0x20`) and the
  chroma AGC (`0x401` bit 7) variants, and checking whether the source's
  colour burst is strong.
* **Field row count** comes out 290–300 instead of exactly 290 — the drop is
  probably slightly more than 16 for some gaps, or a gap occasionally
  straddles a field boundary. Harmless visually.
* The de-shear idea is abandoned: the per-row shift estimate drifts and makes
  things worse. The 32/16 gap is the real structure.

## 10.7 Correction: the gap phase is absolute, not relative (this was the "still missing chunks")

The first cut of the repair detected the gap phase relative to the first
active row but applied it in absolute captured-row space, so the fill landed
one or two lines off. Symptom: the repaired field still had its real gaps
untouched (row-diff max stayed at 49.7) plus a smear where the fill was
injected. Fix is one line:

```python
vals, counts = np.unique((p + act[0]) % gap, return_counts=True)
```

(the diff-series index `p` must be shifted by `act[0]`, the first active row).
After the fix the same field's row-to-row difference max falls

```
field 2   RAW max 49.7  ->  REPAIRED max 4.2   (6 gaps, inserted 16-17 each)
field 5   RAW max 15.4  ->  REPAIRED max 3.8   (5 gaps, inserted 19-20 each)
```

The number of gaps per field varies (5-7) and so does the per-gap count
(15-20), which is why the earlier fixed-16 fill produced 277..312-line fields
instead of 290. The repair is now **per field**: distribute (target 290 -
captured) evenly over that field's gaps.

Also fixed in `decode-clean.py`: the `--grey` output wrote float32 rows into an
8-bit greyscale PNG (declared colour type 0, 1 byte/px) -> black image with
horizontal streaks. Now cast to `uint8`.

### Why async reads don't help

`pctv_probe cap3` keeps 24 URBs of 32 KiB in flight so the device FIFO is
never idle between host reads. Result: 14.9 MB/s vs 15.3 MB/s for the
synchronous `cap2` - i.e. **the ~15 MB/s cap is in the bridge firmware**, not
host read cadence, so the drops cannot be designed away at 720 px. Reducing
`hactive` is the only way to raise the captured line rate (see 10.3).

### Current state

* Geometry: complete. 290 lines/field, gaps filled at the right place,
  no missing chunks. Snapshots in `snapshots/`.
* Colour: present but noisy (chroma neighbour correlation ~0.76 vs luma 0.99);
  chroma noise shows as false-colour blotches on flat areas and rainbow
  fringing on edges. This is the remaining work.

## 10.8 The "hall of mirrors": interpolation smear, cured by merging the two fields

Filling a 15-20 line gap by linear interpolation invents ~30% of the picture,
which reads as a vertical smear / hall-of-mirrors warp (very visible on
vertical edges: table legs, curtains, an outstretched arm).

But the source is film, so **consecutive fields carry the same picture**
(measured correlation 0.93-0.97 at a small vertical shift).  The bridge's
stall is a continuous 48-source-line cycle, so field N and field N+1 lose
*different* source lines: the missing rows of one are real rows in the other.
`decode-clean.py` now repairs both fields to 290 lines while tracking a
`mask` of real vs interpolated rows, finds the vertical shift by correlating
only rows real in both, then fills field N's holes from field N+1:

```
field 2: 193 captured -> 290 (97 interpolated)
         merged with field 3 (shift +4, corr 0.972)
         recovered 96 rows, 1 still interpolated
field 5: 192 captured -> 290 (98 interpolated)
         merged with field 6 (shift -6, corr 0.943)
         recovered 86 rows, 12 still interpolated
field 7: 199 captured -> 290 (91 interpolated)
         merged with field 8 (shift -4, corr 0.930)
         recovered 84 rows, 7 still interpolated
```

So ~90% of the dropped rows are recovered as *real* data.  `--no-merge`
falls back to pure interpolation (kept for comparison).

The remaining shift (~4-6 rows) is presumably the field's own half-line
offset plus residual timing; it does not visibly matter after the merge.

## 10.9 Current state (end of session 10)

* **Geometry: good.** 290 lines/field, interlace recovered by two-field
  merge, no missing chunks, no smear.  Snapshot: `snapshots/2026-10-07-
  alice2-colour.png` (Alice seated) is the clearest.
* **Colour: present, still noisy.** Vivid flat colour is right (blue dress,
  white apron, skin), but there is chroma noise: false-colour blotches on
  flat areas and rainbow fringes on edges (chroma neighbour correlation
  ~0.76 vs luma 0.99).  Next lever: the chroma bandpass/comb, `0x47a`
  (`uv_lpf`) and `0x47b` (`comb`) - in the sweep `lf=2 uv=0 comb=0x40`
  scored 0.82/0.83 and `lf=3 uv=0 comb=0x40` scored 0.89/0.88, against
  0.80/0.79 for the current `lf=2 uv=1 comb=0x20`.

## 10.10 Two remaining artifacts, both diagnosed and fixed

### "Alignment artifact across the top" - merge bands weren't horizontally aligned

The two fields do **not** share horizontal phase: measured over the overlap
the offset wanders by a few pixels (0..6), and it is *locally* different at
the first hole.  So when the merge filled A's hole (rows 32-48 for the Alice
field) with B's rows, that band landed ~5 px sideways and showed as a step
across the picture at the top of her head:

```
band 32-48   aligned by +4  (neighbouring-row estimates: 5, 2)
band 81-96   aligned by  0
band 129-144 aligned by  0
...
```

`merge()` now rolls each contiguous band taken from B to line up with its
neighbouring real A rows (estimating from the row just above and just below
the band, averaged).  The step is gone.

### "Colour artifacts near the black lines" - cross-colour speckle

These are impulsive chroma errors at luma edges (glasses frame, moustache,
hairline): single chroma samples flung to a saturated red/green/magenta.
Two things reduce them:

1. **Better decoder chroma filtering.**  The `0x47a` / `0x47b` sweep showed
   `luma_lpf=3, uv_lpf=0, comb=0x40` (regs `0x47a=0xc0`, `0x47b=0x40`) gives
   chroma neighbour correlation **0.89/0.88** against 0.80/0.79 for the
   vendor-ish `lf=2 uv=1 comb=0x20`.  Now used in `capture-live.sh`.
2. **A chroma median.**  `--chroma-median 3x3` (5x3 for stronger) removes the
   isolated outliers while leaving flat colour alone.

### Repeatable capture

`./capture-live.sh [input] [secs] [tag] [field]` now does the whole chain
with the corrected registers and writes `<tag>-colour.png` / `<tag>-grey.png`
to `snapshots/`.

### State

* Geometry: complete, no warp, no seams.  290 lines/field, ~90-100% of the
  dropped rows recovered as real data from the neighbouring field.
* Colour: natural (blue dress / white apron / skin / green foliage all
  correct) but still somewhat washed out and noisy.  Remaining lever is
  chroma SNR - the median and the filter settings help, a stronger chroma
  AGC setting or software saturation boost is the obvious next try.

## 10.11 Correction: the band alignment was wrong, remove it

§10.10 "fixed" a suspected horizontal phase difference between the two
fields by rolling each merge band.  That was a misdiagnosis: the fields'
black bars line up **exactly** (both at x=87 in the Alice field); the
correlation that suggested a 4-7 px offset was tracking dark, low-contrast
content where nothing correlates well.  The roll then *created* the artifact
it was meant to cure - a notch in the black bar, which is the most obvious
reference in the picture.

Rationale that settled it - the black bar is a physical reference, so measure
it instead of guessing from content:

```
row   |  A bar edge | B bar edge (at merge shift)
 30   |     87      |     87
 36   |     88      |     87
 40   |     87      |     87
 44   |     87      |     87
 48   |     87      |     88
```

=> zero horizontal offset.  `merge()` now defaults to `align=False`;
`--align-bands` keeps the old behaviour for reference.

The **vertical** shift is real and correct, confirmed by measuring the
row-to-row discontinuity at the band boundaries as a function of shift:

```
s=-2   mean row-diff 2.32   boundary diffs 12.2 3.9 8.5 11.7 ...
s= 0   mean row-diff 2.27   boundary diffs  8.9 3.4 6.0  6.3 ...
s=+2   mean row-diff 2.17   boundary diffs  6.8 2.4 2.8  2.4 ...
s=+4   mean row-diff 2.11   boundary diffs  4.5 1.0 1.0  1.1 ...   <-- auto
```

so `best_vshift` is picking the right value; only its *horizontal*
counterpart was bogus.

Lesson: with an animated source, cross-correlation on content is unreliable
in flat/dark regions. Prefer a physical reference (blanking/black bar), or
measure the discontinuity the operation is supposed to remove.

# Session 11 (2026-10-07) — ROOT CAUSE FOUND: the bridge was in the wrong streaming mode

Everything in session 10 was treating symptoms.  The dropped lines were not a
clocking subtlety in the CX25843 at all - the dib0700 **firmware** was in a
streaming mode that cannot carry a PAL signal in real time.

## 11.1 The discovery

`ENABLE_VIDEO` (`0x0f`) payload byte 0 is `(on << 4) | mode`.  Mode 1 is what
the vendor driver and the kernel both use.  Sweeping it:

```
b1=0x10  18.99 MB/s   no BT.656 syncs at all
b1=0x11  15.29 MB/s   10592 lines/s   1444-byte blocks   <-- vendor/kernel mode
b1=0x12  25.62 MB/s   14830 lines/s   1728-byte blocks   <-- 95% of lines!
b1=0x13  0.00 MB/s    nothing
b1=0x14  18.44 MB/s   no syncs
b1=0x15  15.29 MB/s   identical to 0x11
```

A PAL field is 864 samples/line x 625 lines x 25 frames = **27.0 MB/s**.  Mode
1's 1444-byte blocks carry only the *active* part of each line (1440 bytes),
so the line rate is 15.3 MB/s / 1444 = **10 600 lines/s against the 15 625
needed = 68%**.  The bridge cannot buffer a field, so it drops the other 32%
in the mechanical "deliver 32, drop 16" pattern of session 10.

Mode 2 sends the **whole** BT.656 line: EAV (4) + blanking (284) + SAV (4) +
active (1440) = **1728 bytes**, and sustains 25.6 MB/s = **14 830 lines/s =
95% of the 15 625 needed**.  That is the whole fix: in mode 2 only ~10 lines
of 288 go missing (~3.5%) instead of ~96.

## 11.2 Why this was never going to be fixed by tuning

The bandwidth ceiling is in the bridge firmware, not the host:

| experiment | result |
| --- | --- |
| `cap2` xfer size 4096 / 65536 / 262144 / 1 MB | 25.5 / 25.6 / 25.6 / 25.6 MB/s |
| `cap3` async, 24 URBs of 32 KB in flight | 25.6 MB/s (no better) |
| endpoint 0x82 vs 0x83/0x81/0x84/0x85 | only 0x82 ever delivers |
| `channel_state` byte2 tried 01..0f | only 0x01 streams |
| hactive 128 .. 720 | byte rate 10-25 MB/s; mode 2 always wins |

Also: `RQ_SET_USB_XFER_LEN` (0x00) is **ignored** on this unit - `ver` reports
firmware `fwtype=0x00010200` = **1.2.0**, and the kernel only sends that
request for `fw >= 0x10201` (`dib0700.h`).  So the `xferlen` knob does not
exist here, which is why the earlier sweeps did nothing.

## 11.3 Decoding mode 2

The stream is now real BT.656: every line starts with EAV then SAV, each
`FF 00 00 XY` with `XY = 1 F V H P3..P0` (`H`=0 for SAV, 1 for EAV -
observed pairs 0xC7/0xDA, 0x80/0x9D, 0xEC/0xF1, 0xAB/0xB6).  So `V` gives
exact field boundaries and there is a fixed 1440-byte active payload after
each SAV.  `decode-bt656.py` parses that directly - no gap detection, no
heuristic blanking search.

**The residual 5% needs no repair.**  The missing lines are scattered singles
(~10 per 288), so simply rescaling whatever arrived to 576 is clean: the
0.5-3% vertical stretch is invisible and *nothing is invented*.  That is why
session 10's interpolation smeared - it was filling 16-20 line chunks, not
singles.  `--align` (DP unification of the field with its neighbour) exists
but is off by default because it introduces more artifacts than it removes.

## 11.4 Relevant dib0700 source

```c
/* dib0700.h */
#define REQUEST_SET_USB_XFER_LEN 0x00   /* fw >= 0x10201 */
#define REQUEST_ENABLE_VIDEO     0x0f

/* dib0700_core.c, dib0700_set_streaming() */
int onoff = on << 4;
st->buf[1] = onoff | 0x00;        /* 0x00 = MPEG2, 0x01 = analog mode 1 */
if (adap->props.fe[0].caps & DVB_USB_ADAP_RETURNS_DATA_BROKEN)
        st->buf[1] = onoff | 0x01;
```
The kernel only knows 0x00 (MPEG) and 0x01 (analog mode 1); **mode 2 (0x12)
is undocumented** and is what makes analog capture viable on this bridge.

## 11.5 Current pipeline

```sh
./capture-live.sh composite1 5 tag best     # mode 2, picks the most complete field
```
which runs, all through the demod i2c gate:
`cxw 0x401 0xc0` (colour killer off), `0x420 0x80` (saturation),
`0x47a 0x90` / `0x47b 0x20` (chroma lpf/comb), then
`arm 0f 12 01 00` (ENABLE_VIDEO, analog framing, **mode 2**), `cap2`, then
`decode-bt656.py --index -1 --chroma-median 3x3`.

Snapshots: `snapshots/m2live-{colour,grey}.png` (DVD menu, static, geometry
clean).

## 11.6 Field statistics in mode 2

Over a 5 s capture: 251 fields, heights clustered 271-290 with **14 fields at
the full 288**; the rest miss ~10 lines.  `--best` picks the tallest sane
field (ignoring runs >294, which are mis-detected merges).

# Session 12 (2026-10-07) — S-video test, and the chroma turned out not to be there

The DVD menu stayed on the composite input as a stable reference signal.

## 12.1 S-video: connected, selected, and identical

```
sudo ./pctv_probe analog2 svideo1 pal ...
cx25843 id: 0x100=34 0x101=84
input svideo1: mux 0x103=d0 INPUT_MODE=s-video     (composite is 0xf0)
decoder: 0x40d=84 0x40e=7f -> SIGNAL PRESENT
```

So the mux really moved and a signal is present.  The capture
(`snapshots/2026-10-07-svideo-*`) is a complete 288-line field from mode 2.
It is **indistinguishable from composite**:

| metric | composite | s-video |
| --- | --- | --- |
| Cb std | 12.40 | 12.40 |
| Cr std | 9.72 | 9.91 |
| Cb neighbour corr | 0.745 | 0.745 |
| Cr neighbour corr | 0.757 | 0.768 |
| luma neighbour corr | 0.953 | 0.952 |
| chroma gradient at strong luma edges | 22.0 / 19.0 | 22.7 / 18.4 |

That is itself a result: had the edge artifacting been **cross-colour from
composite Y/C separation**, S-video (separate Y and C wires, no comb filter
needed) would have removed nearly all of it.  It removed none.

Caveat: identical numbers in both modes would also be produced if the card
routes composite into the S-video Y pin when only composite is plugged in, so
"is the S-video cable actually connected" is still unconfirmed.

## 12.2 The chroma carries no stable component

Two measurements on complete 288-line fields.

**Temporal.** Averaging the chroma over 12 complete fields:

```
single field      Cb rms dev from 128 : 12.20
averaged 12 fields Cb rms dev from 128 :  2.37
pure-noise expectation (12.4/sqrt 12)  :  3.58
averaged luma std (control)            : 17.40
```

The chroma averages to grey **faster than zero-mean noise would** - i.e. it
has no reproducible component field to field, while the luma keeps its
structure.  (Row-by-row correlation between two complete fields confirms it:
luma +0.96 at zero vertical offset, chroma +0.05.)

**Spatial.** Splitting one field by luma-gradient strength:

```
flat   (|dY|<3)   79% of pixels   |Cb-128|  3.76   |Cr-128|  2.93
mid    (3-10)     13%             |Cb-128|  8.66   |Cr-128|  6.81
edge   (10-25)     6%             |Cb-128| 15.35   |Cr-128| 11.70
strong (>25)       3%             |Cb-128| 33.61   |Cr-128| 26.91
```

The chroma deviation rises monotonically with the luma gradient - the classic
signature of luma leaking into the chroma channel - and flat areas are
essentially neutral.

## 12.3 What this means

For this content the picture is **effectively greyscale**, and nearly all the
"colour" is luma-edge leakage, amplified into visible fringes by the RGB
matrix (R x1.402, B x1.772).  Two consequences:

* The edge artifacting is not "real chroma being mangled" - there is very
  little real chroma to mangle.
* No amount of cross-colour suppression will recover colour that is not in
  the signal; the best available result for this source is a clean greyscale
  image.

Counter-evidence that colour *can* work: the earlier Alice capture
(`snapshots/2026-10-07-alice-colour.png`) showed a large flat area that was
genuinely blue, which requires real chroma on a flat area.

Open questions (need the operator, not the software):

1. **Is the source actually greyscale?**  If the disc is known to be colour,
   a colourless flat area means our decode is wrong; if the menu is
   black-and-white, the measurement is exactly as expected.
2. **Is the S-video cable physically connected?**  Identical stats in both
   modes is what you would see if it is not.
3. A capture of known-colour content would settle both immediately - re-run
   the flat-vs-edge analysis above and the answer is unambiguous.

## 12.4 State of the tooling

Reproduce everything with one command:

```sh
./capture-live.sh <input> <secs> <tag> best
# e.g. ./capture-live.sh composite1 6 menu best
```

`capture-live.sh` does the full correct bring-up and decode:

| step | what |
| --- | --- |
| `analog2 <input> pal ...` | CX25843 firmware, input mux, PAL standard |
| `dwr 1286 0x0000` | demod HIGH_Z, CX25843 is the only bus driver |
| `cxw 0x401 0xc0` | CKILLEN off (chroma enabled) |
| `cxw 0x420 0x80` | saturation 1.0x |
| `cxw 0x47a 0x90`, `0x47b 0x20` | luma lpf 2 / chroma lpf 1, comb |
| `arm 0f 12 01 00` | ENABLE_VIDEO, analog framing, **mode 2** |
| `cap2 0x82 <secs>` | synchronous bulk capture |
| `decode-bt656.py --index -1` | real BT.656 parse, auto-pick a complete field |

`decode-bt656.py` is the decoder that matters now: it parses EAV/SAV directly
(no blanking heuristics), needs no gap filling, and writes colour + grey PNGs.

Superseded, kept for reference: `decode-clean.py` (mode 1 gap-filling and
two-field merge - the whole apparatus that mode 2 made unnecessary),
`decode2.py`, `decode-color.py`, `decode-field.py`.

Probe commands added along the way: `cxr`/`cxw` (2-byte gated CX25843 access),
`cap3` (multi-URB async capture, used to prove the 25.6 MB/s ceiling is in the
bridge firmware), and `PCTV_XFER`/`PCTV_URB` env knobs.

## 12.5 Snapshot index (`snapshots/`)

| file | mode | note |
| --- | --- | --- |
| `2026-10-07-menu-composite-{colour,grey}.png` | 2 | complete 288-line field, current best geometry |
| `2026-10-07-menu-svideo-{colour,grey}.png` | 2 | same content over S-video |
| `2026-10-07-alice-colour.png` | 1 | the one capture where real flat colour appeared |
| `2026-10-07-interview-colour.png` | 1 | live-action shot |

---

# 13. The kernel driver (`driver/`) — 2026-10-07

Everything above is now a kernel module instead of a libusb script:
**`driver/pctv320cx.ko`**, Rust core + C V4L2 glue.

## 13.1 Shape

| file | lines | what |
| --- | --- | --- |
| `driver/pctv320cx.rs` | ~1300 | Rust: DiB0700 firmware download, vendor I2C tunnel (gate + 16-bit sub-address), CX25843 std/input/control programming, 8 x 64 KiB bulk-IN URB ring, BT.656 -> YUYV deframer, probe/disconnect |
| `driver/v4l2-glue.c` | ~600 | `video_device`, `vb2_queue` (vmalloc), ioctl table, control handler (brightness/contrast/saturation/hue), buffer handoff to the Rust side |
| `driver/usb-shim.c` | ~130 | `struct usb_driver` + `MODULE_DEVICE_TABLE`, endpoint/pipe helpers, `request_firmware` wrapper, gfp helpers |
| `driver/pctv320cx.h` | ~160 | the seam: `struct pctv_ops` (C -> Rust) and `pctv_glue_*` (Rust -> C). Also the bindgen input |
| `driver/Kbuild` | ~75 | kbuild rules, including **bindgen-generated bindings** for the Rust half |

The Rust side sees the kernel through bindings generated at build time from
the target kernel's own headers — the same recipe as the in-tree
`rust/bindings` crate (`bindgen_parameters` is a copy of the kernel's, minus
the `--with-attribute-custom-enum` lines that need in-tree `#[cfi_encoding]`
support). `$(obj)/pctv320cx_rs.o` is built with kbuild's own `rustc_o_rs`
rule, so the module links against the real `kernel` crate of that kernel.

## 13.2 What the port had to work around (kernel 7.2.3)

* `vb2_ops.wait_prepare/wait_finish` are gone (the core takes `q->lock`).
* `vb2_queue.min_buffers_needed` -> `min_queued_buffers`; no `timeout` field.
* `vb2_streamon()` takes no gfp mask any more.
* `vidioc_enumstd` no longer exists — ENUMSTD is served from `vidioc_g_std`.
* `vb2_get_timestamp()` is gone; the core stamps buffers itself.
* `v4l2_ctrl_handler.priv`, `video_device.parent` gone; `v4l2_device.dev` is a
  pointer now.
* `usb_alloc_coherent(dev, size, mem_flags, dma_handle)` — mem_flags moved
  before the dma handle.
* `gfp_t` is opaque to bindgen: the shim exports `pctv_gfp_kernel()/
  pctv_gfp_atomic()` so the Rust side never needs the macros.
* `get_unmapped_area` is not exported to modules — v4l2-dev installs it on the
  internal fops itself, so the driver must not set it.
* `module!` params must be integer types (`bool` panics the proc macro) and
  its metadata are plain `"..."` literals, not `b"..."`.
* `KBox::pin_init` returns a `Pin`; post-init field writes go through
  `as_mut().get_unchecked_mut()` with a SAFETY comment (the box is never moved
  again).

## 13.3 Hardware facts the driver encodes (all from sections 8-12)

* firmware download over bulk-OUT EP1 with the vendor record framing, then the
  jumpram request; the bridge NACKs `RQ_NEW_FIRMWARE_STATUS` until it runs.
* I2C tunnel: `RQ_NEW_I2C_WRITE` record `[req, addr<<1, ctrl, bus]`, gate
  opened by a write to the bridge's own pseudo-address `0x40`, CX25843 at 7-bit
  `0x44`, demod at `0x48`.
* `0x401 = 0xc0` (colour killer / chroma AGC) — with the vendor's `0x60` every
  even byte is pinned at `0x80` and the picture is grey.
* saturation is reg `0x420`/`0x421` = `val << 1` (in-tree cx25840 mapping), so
  the V4L2 default 64 lands on `0x80` exactly as the script's `cxw 0x420 0x80`.
* demod register 1286 = 0 releases its hold on the parallel bus.
* arm: release channels 0..3 (`0f 00 01/02/04/08 00`), then
  `0f 12 01 00` = ENABLE_VIDEO, analog framing, **mode 2**.
* 288 active lines per PAL field on the wire, 1728 bytes per line, 1440 bytes
  of active YUYV after each SAV.

## 13.4 Build / deploy

```sh
cd driver && make                      # against the running kernel (needs CONFIG_RUST=y)
make KDIR=/lib/modules/<v>/build       # or a prepared build tree
```
NixOS: `nixos-module.nix` -> `hardware.pctv320cx.enable = true` (adds the
module to `boot.extraModulePackages` + `boot.kernelModules`, pulls
linux-firmware for `dvb-usb-dib0700-1.20.fw` and `v4l-cx25840.fw`, and keeps
`dvb_usb_dib0700` off the card). Enabled on `macbook-pro-2009-nixos`; the
Win7-VM USB passthrough that used to own the card is retired.

Verified: builds warning-free against 7.2.3, `modinfo` shows the 2304:022e
alias, both firmware entries and the videobuf2 dependencies. **Not yet run
against the card** — first hardware run is `dmesg | grep pctv`, then
`v4l2-ctl -d /dev/video0 --all` and a capture.

---

# 14. The last two picture defects: vertical jiggle and the chroma "ramp" — 2026-10-08

After §13 the driver produced a stable, correctly-framed picture, but the
live view still showed a few lines of vertical jiggle on a *still* source
(a DVD menu), and the chroma fringing on sharp edges was suspected of
worsening a few seconds after the signal appeared. Both were chased down
with a 12 s / 307 MB raw capture (`pctv_probe analog2 svideo1 …`, i.e. the
libusb path, unaffected by the driver) and a 15 s driver capture
(`/dev/video0`, UYVY 720x576).

## 14.1 The jiggle is line drops plus an F-based field boundary

Mode 2 still drops ~5% of the active lines (the bridge tops out at
25.6 MB/s, PAL needs 27.0). Two things turned that into visible motion:

1. **Whole-field shift.** The old deframer completed a frame on the F bit
   changing. The CX25843 flips F **one line early** - a single active line
   at the end of a field already carries the next field's F - and if the
   bridge drops that lone line (it is exactly the kind of line mode 2
   loses) the boundary slips a whole line. Measured correlation of each
   field against a reference of the same parity, band by band, showed bands
   of the field displaced by 2-8 lines relative to each other, i.e. the
   field was both shifted and internally inconsistent.
2. **No vertical resampling.** The survivors were written straight into
   their nominal rows (line k -> row 2k+field), so every dropped line pulled
   the rest of the field up by one. Across a field this showed as the bottom
   of the picture walking up and down; the whole-frame cross-correlation had
   a standard deviation of ~4 lines and excursions to ±21.

Both are fixed in `driver/pctv320cx.rs`:

* **Fields are delimited by V, not F.** The vertical-blanking run is ~22
  lines wide, so the V=1 -> V=0 transition is a far steadier anchor than a
  single F-tagged line. Consecutive V=0 runs are one field each and their
  output parity alternates (even/odd rows = `V4L2_FIELD_INTERLACED`).
* **Each field is accumulated in a scratch buffer** (`vmalloc`, 288 x 1440
  bytes, `FIELD_SCRATCH_BYTES`; shims `pctv_vmalloc`/`pctv_vfree` in
  `usb-shim.c`) and, once its true line count N is known, **resampled onto
  the fixed 288-row grid** with 8-bit linear interpolation. Missing lines are
  spread evenly instead of shifting everything below them.

Result on the 15 s driver capture (375 frames):

| metric | before | after |
| --- | --- | --- |
| reported fps | 26.4 | **25.00** |
| consecutive-frame vertical shift | ±2..±12, 0 in 38/119 | **0 in 99/119**, never beyond ±2 |
| even/odd field mismatch (mean abs luma) | ~37 | **3-6** |

A resampling simulation on the same raw data reproduced this off-line
(_what if we resample_: full-field shift stdev 2.89 -> 0.29 lines, frame
shifts pinned to 0) before the driver was touched.

## 14.2 The chroma "gets worse" is the 0x401 fast-lock bit

`0x401` bit 7 is a fast-lock / forced-acquisition bit for the chroma AGC
and colour-killer; the in-tree `cx25840` sets it only in
`cx25840_set_fmt()` (`cx25840_initialize()` deliberately writes `0x40`) and
`cx25840_s_ctrl()` clears it again for manual chroma controls.

Measured edge-chroma magnitude per field, `0x47a=0x90`, `0x47b=0x20`:

* `0x401 = 0x40`: edgeCb **21.1 -> 18.8 -> … -> 3.5** over the first ~4 s,
  then flat. That is the ramp.
* `0x401 = 0xc0`: edgeCb **pinned at 1.4-1.6 from the first field**, flat
  for the whole 10 s capture.

So the "starts ok then gets worse" behaviour is chroma AGC slow-locking:
with bit 7 clear the loop walks in over a few seconds. The driver already
uses `0x401 = 0xc0` (`input_setup()`), and a 20 s driver capture showed
edgeCb flat (per-25-frame means 31.0-31.3, min 26.6 max 33.5 - no trend),
so the ramp is **not** present on the driver path. It was only visible on
the libusb path when `capture-live.sh`/`pctv_probe` were run with `0x40`.

Caveat: the same capture is a DVD menu with no true chroma content (§12),
so "chroma fringing" on its hard edges is cross-luma / decoder peaking
rather than real hue. The constant rainbow fringe that remains on the
driver output is that edge response, not a time-varying defect.

## 14.3 Robustness fixes and build

* `finish_frame()` now guards a null videobuf2 buffer (queue dry when the
  frame was assembled) - previously that path could call
  `pctv_glue_buffer_done(glue, NULL, …)`.
* `op_set_std()` resets the deframer too, so a standard change re-derives
  the output field height (288 PAL / 240 NTSC).
* Build: `./build-module.sh --max-jobs 4 --option builders ''` (the zen3
  build machine rejected the SSH key during this session; local build works
  and is ~5 min). Module `sha256 6d26c687a70adb9a…`,
  `/nix/store/zfnqlqchzd36m6zkhlxmk799vf98zkf3-pctv320cx-0.1`.

## 14.4 State when this session ended

* The **resampling fix was verified on hardware** (module
  `…-fan7qif8…`, `sha256 a5332ca7cb2bb65e…`): 375 frames at 25.00 fps, the
  jiggle gone, `snapshots/`-comparable image clean and single.
* The null-guard / `op_set_std` additions (`…-zfnqlqch…`) were built but
  **not re-run on the card**: during the final rebuild the host hard-crashed
  and rebooted (nouveau BAR fault was logged ~8 min earlier when qv4l2 was
  killed; the crash itself left no oops) and came up with the DiB0700
  **cold-wedged** - `GET_VERSION` NACKs even over libusb, so the fixes could
  not be exercised. A physical power-off (HANDOVER §0) is required.
