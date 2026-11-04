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

**Raw masters go to the NAS** (`rawMasterMount`, `rawMasterShare`). A lossless UYVY +
PCM master is 20.9 MB/s, which no laptop SSD in the house should be asked to hold for
2 h, so `pctv-capture-nas` sets `PCTV_MASTER=uyvy` and
`PCTV_OUT_DIR=<rawMasterMount>/pctv-masters`, and the desktop gets a second entry,
*"PCTV Capture (raw master to NAS)"*. It **refuses to start when the mount is not
there** (`findmnt -T … -t nfs4`): a capture pointed at a directory that is merely the
mount point, locally, would write 12 GB to the SSD, look exactly like success, and
fail at the worst possible moment. `rawMasterShare` stays `null` when the machine
already mounts the export — macbook-pro-2009-nixos takes `/ds-public` from
`common/nfs.nix` and sets only `rawMasterMount`, rather than mounting the same export
twice and having two caches disagree about which one a file landed in.

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

## 10. Capture masters, field order, and getting 50p

A capture is 25 frames/s of **625/50 interlaced** video — 720×576, 4:2:2, 50
fields/s. Every choice in this section follows from that: the card already hands
us 50 temporally distinct images per second, so the only questions are what gets
written and what happens later.

### 10.1 The three masters (`--master`, `PCTV_MASTER`)

| mode | container / codec | disk rate | encoder, measured¹ | quality² |
| --- | --- | --- | --- | --- |
| `dvd` (default) | MPEG-PS, `mpeg2video` `-b:v 6000k -g 15 +ilme+ildct` | 0.72 MB/s | 5.1× realtime | SSIM 0.970, PSNR 43.8 dB |
| `dvd --bitrate 15000` | the same at 15 Mbps | 1.33 MB/s | 4.7× | SSIM 0.985, PSNR 47.0 dB |
| `utvideo` | Matroska, `utvideo` (yuv422p), all-intra | 5.1 MB/s (300 MB/min) | **14×** | lossless, **no field order written** |
| `ffv1` | Matroska, `ffv1 -g 1` (yuv422p) | 4.0 MB/s on grainy tape | 4.5× | lossless, frames flagged TFF |
| `uyvy` | Matroska, `rawvideo` (uyvy422) | 20.7 MB/s (1.2 GB/min, ~35 GB per tape) | 8.0× | lossless, frames flagged TFF, but skipped 17 frames in 60 s |

¹ ffmpeg's own `speed=` with every mode fed the *same* raw UYVY the capture
pipeline produces, so the figures are comparable; >1× means it keeps up.

² Measured 2026-11-02 on one 60 s take: capture a `uyvy` reference, transcode it
with each candidate, compare with `ssim`/`psnr` over the same 1482 frames.  So
the two lossy rows are the *only* difference between what this card delivered and
what the file holds.  `ffv1`, `ffvhuff` and `utvideo` decode **bit-identical** to
the reference (`framemd5` per frame), i.e. the lossless modes are actually
lossless on 4:2:2 8-bit; `libx264` at `-qp 0` is lossless too but runs at
**0.71×** realtime here, and `-crf 12` at 0.48×, so x264 is not an option at any
quality setting on this box.

`ffv1` is the archival master of choice now, and the deciding property is not
speed or size: it is the only fast lossless codec here that **writes the field
order into the file** (the decoded frames come back `interlaced_frame=1,
top_field_first=1`).  `utvideo` is three times faster and the same size, but it
writes neither a bitstream flag nor a container element - every frame decodes as
`0,0` - so a plain player shows it as progressive and either combs or falls back
to 25p, which is precisely the smoothness the archive exists to keep.  If you do
use `utvideo`, `pctv-field-order --relabel FILE` fixes the container in one
stream copy (verified: `field_order` goes `tb` → `tt`), and the capture prints a
reminder when it stops.  `uyvy` keeps the flags but costs 20.7 MB/s of writer
bandwidth and **lost 17 frames in the same 60 s** on this box.

MPEG-2 has no quality headroom left to buy: `-b:v 15000k` and `-b:v 25000k`
produce the *same* 83 MB for that minute, because the encoder runs out of
quantiser (q=2) before it runs out of bitrate.  So `--bitrate 15000` is the
ceiling for MPEG-2 here, ~47 dB PSNR - good, but not the same thing as lossless.

### 10.2 Why the capture box must not deinterlace

The ask was 50 fps smoothness, a less-lossy codec, and post-processing for
de-interlacing on a fast machine. The first two are §10.1; the third is why the
capture stays dumb. At full 576 lines, 50 distinct images/s and progressive
frames are mutually exclusive — a field is 288 lines, so 50p means inventing 288
lines fifty times a second:

* **bob** (`yadif`/`bwdif` single-rate) is real-time and throws half the vertical
  resolution away *permanently*. Doing it at capture is irreversible.
* **motion-compensated interpolation** (QTGMC, `nnedi3`) is quality, not speed — a
  many-pass VapourSynth job, and this box is a 2-core T9800 whose whole job is to
  never drop a field.
* **fields are not damage.** They *are* the 50 Hz information; the archive keeps
  them and the post box decides. Verified on this very ffmpeg: 50 interlaced
  frames through `bwdif=mode=send_field:parity=tff` → 100 frames at 50/1 fps and
  the full 576 lines. QTGMC on the same fields is the archival answer.

So no `-vf`, no crop to 702, no `scale`, in any mode — and `uyvy`/`ffv1` are the
modes to archive a tape in, with `dvd` for the copy you actually play.

### 10.3 Field order: the pixels are TFF, and only one of the three tags says so

* **By construction, and by the standard.** The deframer (`pctv-monitor.c`, the
  `F`-bit branch of the BT.656 parser) puts field 1 on the *even* lines. ITU-R
  625/50 numbers the field containing line 1 as field 1 — so field 1 *is* the top
  field — and displays the field it transmitted first. That is the same reason
  DV-PAL files are always TFF; an analog camcorder's field sequence is the
  broadcast sequence it came from.
* **It cannot be measured with `idet`, which is a trap worth writing down.**
  Field-order *lean* from `idet` looks like an instrument and is not one on this
  material: two synthetic clips built identically except that in one the even
  lines sample the earlier instant and in the other the odd lines — i.e. TFF vs
  BFF by pure construction — voted `TFF: 9 BFF: 10` and `TFF: 10 BFF: 9`, with
  116 of 150 frames `Undetermined`. ffmpeg also prints a spurious all-zero idet
  summary *before* the real one, so a `head -1` on that output silently reads the
  zeros (an earlier revision of this section quoted `TFF 817 / BFF 183` from
  exactly that kind of mis-read; `pctv-field-order` now takes the last summary).
  What idet *does* answer is whether the picture is interlaced at all: over 100
  frames five minutes into a tape, `Repeated Fields: Neither: 58 Top: 19 Bottom:
  23` — 58 % non-repeating is interlaced, not progressively encoded.
* **Then contradicted by the file - until the flag went in the right place.** The
  `.mpg` masters report `field_order=bb`/`top_field_first=0`, and the comment in
  `cap_start()` concluded from that that `mpeg2video` **ignores `-field_order`**
  and writes the bitstream flag itself.  That conclusion was wrong, and it was an
  artefact of *where the flag was being passed*.  Measured on this box against the
  same rawvideo demuxer the capture pipe uses, with
  `-c:v mpeg2video -flags +ilme+ildct -f mpeg`:

  | where `-field_order tt` is passed | `field_order` | `top_field_first` |
  | --- | --- | --- |
  | before `-i` (input/demuxer side) | `tt` | `1` |
  | after `-i` (encoder side) | `bb` | `0` |
  | not passed at all | `bb` | `0` |

  `mpeg2video` does not ignore the flag - it **records the order the demuxer
  reported**, and a raw demuxer reports nothing unless you tell it.  Encoder-side
  is indistinguishable from silence, which is what made the wrong conclusion look
  right.  So every `.mpg` this tool wrote was declaring bottom-first because it
  was never being told, and MPEG-2 defaults to bottom-first.  All three masters
  now pass the flag on the input side.  The flag is metadata: encoding 4 s of tape
  told and untold and diffing the decoded frames gives **PSNR `inf` /
  SSIM 1.000000**, so correcting it cannot move a pixel - verified with `+ilme`
  on, where interlaced motion estimation is exactly the thing you would fear.

  Because the flag is a *syntax element of the picture coding extension*, files
  written before the fix cannot be relabelled losslessly: `ffmpeg -c copy
  -field_order tt` rewrites the Matroska label while the decoded frames go on
  reading `1,0` (measured; the remux also needs `-fflags +genpts` or the muxer
  dies on an audio packet with no valid timestamp).

Which is why the master modes all pass `-field_order tt` **on the input side**:
with a raw source that is the only place ffmpeg listens, and it puts the value
where consumers actually look - every decoded frame carries
`interlaced_frame=1, top_field_first=1`, the flags `idet`, `yadif`/`bwdif`, ffms2
and l-smash consult. (ffprobe then *spells* the stream-level tag `tb`; that is an
ffmpeg quirk, the frame flag is the operative one.)

`pctv-field-order` (same package) prints all three readings for a file and what
to do about each; `--relabel` stream-copies a container-tagged Matroska twin and
honestly reports that the frames kept their own flag. For the `.mpg` masters
recorded before 2026-11-02 the fix is one line in the post script - AviSynth+
`AssumeTFF()`, VapourSynth `core.video.AssumeTFF(clip)` / `SetFieldBased(1)`.
Tape digitising has always declared its field order; trusting the tag was the
experiment.  The same applies at *playback*: a player that believes the wrong
order deinterlaces every moving object backwards, which looks like motion that
draggs and then catches up.  `ffplay -top 1 FILE` forces the MPEG-2 decoder's
field order for those older files - a capture made after 2026-11-02 says `tt` and
needs no flag at all.  Check which you have with
`ffprobe -select_streams v -show_entries frame=top_field_first -of csv=p=0 FILE`.

## 11. Cadence: why a recording was less fluid than the live view (2026-11-01)

Reported symptom: the live monitor is smooth, the recorded file is not - the
frame rate "drags a bit then catches up", audio sometimes a second out, worse as
a long tape runs.  Reproducible, measurable, and the cause was not the USB link,
the encoder or the disk.  All numbers below are from this box.

**The 2 h tape** (`pctv-cap-20261101-155418.mpg`, 184 854 frames):

| reading | value | what it means |
| --- | --- | --- |
| video stream duration | 7394.160 s | CFR: 184 837 PTS deltas of exactly 0.040 s |
| audio stream duration | **7396.536 s** | **2.376 s = 59 frames of picture gone** |
| PTS deltas of 0.080 s | 8 | eight hard 40 ms jumps in 2 h |
| decode-only speed | 22x (12x with `bwdif`, 7x with `yadif`) | the player was never the limit |
| probe / ring / queue drops | 0 | the byte stream was intact |

So the file is a perfectly regular 25 fps that is quietly **shorter than its own
sound**, and a file that is short against its audio is a file whose picture
creeps ahead of the speech: exactly "up to a second out, sometimes".

**A 120 s capture of a moving tape, old code:** 2991 frames written, of which
`374` were `repeated` (12.5 %), while ~375 freshly assembled frames never
reached the file at all - and nothing counted that second direction.  Corroboration
from the artifact (decode at 80x60 grey, compare neighbouring frames): 17.9 % of
consecutive frame pairs in that file are near-identical, mean abs diff 2.24
against 11.30 for real motion - read with the caveat in "how to check a capture",
because a still scene on tape looks the same way.  The counters said 12.5 % on
their own.

### The clean A/B (same tape, consecutive minutes, same box)

| | old binary | new binary |
| --- | --- | --- |
| frames assembled (fields / 2) | 1509 | 1483 |
| frames written | 1508 | **1483** |
| duplicates (`dup`) | **149 = 9.9 %** | **2 = 0.13 %** |
| assembled but never written | ~150 = 10 % *(inferred, uncounted)* | **0** |
| video vs audio stream duration | 60.320 / 60.264 s | 59.320 / **59.328** s |
| stream-queue drops | 0 | 0 |

`frames written == frames assembled` is the property that matters: every picture
the decoder delivered reached the file exactly once.  The old binary could not say
that in either direction - it counted the duplicates and not the overwrites, and
the two together were a fifth of a minute of tape.

### The cause

Two clocks and one buffer. `fuv` holds "the newest assembled frame", and the
encoder was fed by polling it whenever **40 ms of host time** had passed, from
the main loop - whose iteration period is 17-28 ms, i.e. half the frame period.
A poll has only two ways to be wrong and it had both: fire before the card
finished the next frame and you write a **duplicate** ("drags"); fire after two
frames arrived and one is overwritten unfed, a **skip** ("catches up") that also
shortens the video track by 40 ms *forever*, because the container is CFR and the
sound is counted in samples. The card is a third crystal again (CX25843 13.5
MBaud / 1728 B / 625 lines), so no fixed offset between them survives a tape.

### The fix (same day)

1. **Every frame is queued where it is born.** `field_commit()` pushes into a
   12-slot ring (one slot reserved for the frame in flight, so 10 deep = 400 ms);
   nothing can be overwritten any more, and an eviction is a deliberate, counted
   event (`skip`).
2. **The clock moved to the consumer and onto the audio stream.** One writer
   thread owns every write to ffmpeg and pops one frame per 40 ms **of audio
   track**, not of host time - because that timeline *is* what the file's PTS ramp
   encodes, so frame k lands where the audio says 40 ms x k and the two streams in
   one file are consistent by construction.  The clock is `accepted - evicted`
   samples, deliberately not "bytes written": a program-stream muxer waiting for
   video stops reading fd 3, so a clock derived from writes waits on the very frame
   it is holding back.  With no audio, and after a 1 s audio stall, it falls back
   to the wall clock.
3. **Be late rather than duplicate:** a queued frame goes out the moment it
   exists (no aligning to a boundary), and a duplicate is only written 30 ms after
   the deadline passed with nothing queued.
4. **Audio is queued too** (1 MiB = 5.5 s) instead of `O_NONBLOCK`-and-drop, the
   capture PCM asks for 60 ms of latency instead of 20 ms, and both encoder pipes
   are non-blocking with `pipe_write()` resuming a partial frame - rawvideo has no
   framing, so half a frame is not a lost frame but a corrupted stream.  Bytes the
   pipe would not take stay in the ring: that is an encoder running late, not a
   dead one (see the traps).  The video ring is 24 frames = 960 ms by default,
   `PCTV_VQ_SLOTS=4..32`.
5. **The probe no longer destroys data on EAGAIN**: the libusb callback fills a
   64 MiB ring (2.4 s) and a writer thread drains stdout, so a slow consumer costs
   latency instead of 32 KiB of BT.656 per hiccup. `PCTV_STREAM_BUF=<MiB>`, `=0`
   restores the old behaviour for an A/B run.

**60 s after:** 1509 frames written, `dup 1`, `skip 0`, queue high-water 1, 0
stream drops; video 60.360 s against audio 60.336 s (one mp2 frame), both streams
starting at PTS 0.000000 - no offset and no accumulation.  **300 s after:** 7515
frames, `dup 39` (0.5 %), `skip 1`, 0 drops of any kind - and those 39 line up
with the 74 *stale-field feeds*, the times the decoder itself delivered the same
field parity twice.  That is the floor: a card that drops a field costs one
repeated frame, and no buffering prints a picture that was never sent.

**All three masters, store-built binary:**

| mode | length | frames | dup | skip | queue max | drops |
| --- | --- | --- | --- | --- | --- | --- |
| `dvd` (mpeg2 6 Mbps) | 60 s | 1509 | 4 | 0 | 1 | 0 |
| `ffv1` (lossless, 422 MB) | 60 s | 1509 | 3 | 0 | 1 | 0 |
| `uyvy` (uncompressed, 948 MB) | 45 s | 1132 | 4 | 0 | 1 | 0 |

Frames written equals fields assembled in every one.  FFV1 kept up on this tape
(7 MB/s out) with the queue never even filling; an earlier build fell behind in
bursts on a grainier passage, which is what the deeper ring and the `skip` counter
are for - if `skip` climbs, the encoder is slower than real time and `--master
uyvy` (a memcpy) is the mode that structurally cannot be.

### Traps that cost an hour each

* **The writer must not count its duplicate source as "work".** It holds the last
  frame so it can re-send it when the card has not produced a new one; treating
  that as pending work made the drain loop re-send the last frame into ffmpeg
  forever, so `cap_stop()` never returned, the main loop never pumped the probe
  again, and 480 MB of tape went past into a full stream queue on every stop.
  Draining also has to refuse *new* audio (`aq_closed`) - and refuse to block,
  because ffmpeg's s16le input will wait for samples that a closed queue will
  never send, which deadlocks the muxer against the writer.
* `pthread_cond_timedwait` times out on **CLOCK_REALTIME**; build the abstime with
  `clock_gettime(CLOCK_REALTIME, ...)`, not `CLOCK_MONOTONIC`.
* **Two `stream` runs on one card do not fail - they corrupt.** libusb's
  `claim_interface` is what keeps a second reader out, and the probe treated
  `Resource busy` as a warning and submitted URBs anyway: the kernel was happy to
  hand the endpoint's bytes to whoever polled first, so the *existing* capture -
  the one whose operator is watching - starts seeing spliced lines, holds its
  gate, and its file grows frame holes while its sound path is shared with a
  second ALSA client and starts reading alternation between programme level and
  digital silence (which the AGC then hunts, at ten console lines a second).
  Observed 2026-11-01 when an agent ran a "quick verification capture" over a
  user's tape; the holes in the user's file were the evidence.  `stream` now
  treats a failed claim as fatal (`ctl`/diagnostics still tolerate it, because
  re-tuning a live capture is a legitimate thing to do), and the monitor logs to
  a file when detached so the counters outlive the desktop launcher.
* **A stalled encoder is not a dead encoder.** An intermediate version called
  `cap_died()` when an audio write did not finish in 3 s - and a muxer waiting for
  video does exactly that, so an FFV1 capture at about 1.0x died at 42 s with
  "encoder went away", with nothing from ffmpeg because nothing crashed.  Bytes
  the pipe will not take now stay queued, `-1` means EPIPE and only EPIPE, and the
  counters say what actually happened.
* `char *av[48]` with 49 entries writes the NULL off the end of the stack, and it
  **only showed up in the nix-built binary** (`ffmpeg ... -s ""` →
  `Unable to parse "video_size" option value ""`), not in the hand-built one.  The
  array is 64 now and `PCTV_FFMPEG_DEBUG=1` prints the whole command line; build
  the way it ships before believing a capture works.

### How to check a capture

```
PCTV_VERBOSE=1 pctv-monitor ...      # per second: q <depth> dup N skip N
pctv-field-order FILE                # what the file claims about field order
ffprobe -show_entries stream=codec_type,duration,nb_read_packets \
        -count_packets -of default=nw=1 FILE     # video packets == fields/2
```

The line at the end of a capture is the summary: a clean one reads
`[dup 0, skip 0, qmax 1], 0 video drops, 0 audio drops`. `dup` and `skip` grow
only if the card and the host actually disagree; anything else is a regression.
Compare the two stream durations the same way: they should agree to one audio
frame (24 ms mp2, 1 ms pcm), not to seconds.

And do **not** try to measure dropped or duplicated frames by pixel-comparing
decoded frames.  Decoding to 80x60 grey and calling a consecutive pair identical
when the mean difference is under ~1.5/255 works in principle and misleads badly
in practice on VHS: a still scene, a pause and a tracking fault all read as
repeats - it reported 30 % on a minute whose own counters said 0.13 %.  Packet
sizes are no better: a duplicated frame is not reliably cheap on an `+ilme`
interlaced encode (min 13 kB at 6 Mbps on a detailed tape, 350 B on snow).
Use the counters and `nb_read_packets`.

## 12. End of tape: a frame that never changes, and what to do about it (2026-11-02)

A camcorder at the end of a tape does not stop the digitiser: it hands the card a
still frame for ever. The predicate is exact rather than statistical, because "for
ever" means **bit-identical** - nine hours of end-of-tape hold hash to one value (and
read Y=16, U=128, V=128, video black, at t=5890 s and again 7 h later), while every
one of the 960279 frames of programme before them differed. Live tape that merely
*looks* still differs too: a held shot at 0.035-0.049 mean inter-frame difference
against exactly 0.0000 for a frozen feed, so two orders of margin separate "nothing is
happening" from "something is happening very quietly".

### What the monitor does, which is not "stop"

`pctv-monitor` folds every frame it would encode into 64 bits and watches the run
length. After `PCTV_HOLD_SECS` (**600** since 2026-11-03; 120 before) of an unchanged
picture it **closes the file and keeps the card**, then opens a new file once
`PCTV_HOLD_RESUME` frames (1 s) have changed. The overlay reads
`STILL mm:ss - file closed, waiting`, the window title gains `[STILL]`, and `c` re-arms
the window and cancels the automatic reopen, because a person has then decided what to
record.

120 s was too short, and the reason is not the end of a tape but a **damaged** one.
The frame gate replaces every unclean frame with the last clean one, so a stretch of
dropped-out tape is bit-identical frame after frame *exactly like* a deck that has
stopped - at 2 min the file was cut in the middle of the damage (2026-11-03) and then
nothing further was recorded, because the monitor was waiting for a picture that was
not coming back on its own. Ten minutes costs 27 MB of frozen tail when it is wrong
(45 kB/s) and leaves the rest of the tape in one file when it is right. The real end
of a tape has an unambiguous answer of its own - the blue screen, below - in 60 s.

Closing-instead-of-stopping is still the point for a *frozen* picture. Nothing can
tell a blank stretch between two recordings apart from the end of a tape, so any rule
confident enough to end the run is confident enough to discard the rest of the tape -
and the costs are nowhere near symmetric: the programme runs at 699 kB/s and a frozen
frame at 45 kB/s (24 kB/s of that is the CBR mp2 track), so recording through a blank
is 1 % of the disk while stopping through one loses the programme. `PCTV_HOLD_MAX 900`
does end the run, 15 min after the picture stopped, for the case where nobody is there
and the card should be released; at 0 it keeps watching and costs nothing, because the
file is already shut. Verified with `PCTV_HOLD_STRESS`, which reports a frozen picture
for the first N seconds whatever the deck is doing: 151 frames in 6.05 s, file closed,
then 425 frames in 17.02 s in the next file, `field_order=tt` and `dup 0 skip 0` on
both sides of the boundary.

What it cannot see is a deck that answers end of tape with *static*: snow changes
every frame, so it is programme-shaped to this and to every growth-rate detector
below. `--capture-seconds` is the honest answer for that deck.

### The external watchdog: still there, no longer the main line of defence

Before the monitor could see this, the only window onto it was the file. On the DVD
master the symptom is a **collapsed bitrate**, because the encoder is rate-capped
(`-b:v 6000k -maxrate 6000k`): live programme measures 774 kB/s of file growth and a
frozen frame drops to a trickle (a 10 h 40 m capture of a 98 min tape averaged
1.19 Mbit/s against 6.2 Mbit/s for the programme). `scripts/pctv-autoend.sh` watched
exactly that - below `PCTV_END_RATE` (150 kB/s) for `PCTV_END_CONFIRM` (600 s) it sent
SIGTERM to the monitor - and with the detector above it is now the fallback rather
than the plan, since it has to average a rate across a window (≈9 min of frozen frame
before it fires, and a mid-tape blank that long is indistinguishable from the end).

**It has already failed once.** The first night's run died 11 min in and the capture
ran 9½ h past the end of the tape. The loop kept its samples in a bash array,
read `n=${#TS[@]}`, then trimmed the oldest sample and still indexed
`TS[n-1]` — one past the shrunken end, unbound under `set -u`, so the script
exited. It is a one-line fix, but the reason it survived review is that nothing
tested the loop past its first trim, so `scripts/pctv-autoend-test.sh` now does:
it fakes a monitor and an encoder (matched by command line, exactly as the watchdog
matches them), grows a file at 800 kB/s, stops, and asserts the watchdog survives
the trim and stops the monitor. `./scripts/pctv-autoend-test.sh` — run it after
editing the watchdog; it also runs against a copy of the old script and reproduces
the 2026-11-02 crash verbatim (`line 77: TS[$((n-1))]: unbound variable`). That is
the same lesson the monitor learned the hard way: the process that watches is the
one that dies unnoticed, so the watching belongs next to the frames.

### The still that is not frozen: 69 min of blue that changes every frame (2026-11-02)

The tape `pctv-cap-20261102-145124.mpg` ran 8254 s for 69 min 16 s of programme.
The detector above did not fire, and measuring why destroyed the assumption that a
no-signal field is a *flat* one:

| what | measured |
| --- | --- |
| programme ends | t=4156 s (file growth 750 kB/s with full luma until then) |
| 4156 → 8210 s | the deck's blue: **749 consecutive frames, zero identical pairs**, mean absolute inter-frame difference 0.0199 |
| 8210 → 8254 s | video black (Y=16, U=V=128) — but only 44 s, under `PCTV_HOLD_SECS`, then 120 |
| so | `hold_same` never reached 3000, `PCTV_HOLD_MAX` was 0, and the rate watchdog was not running |

**Why the blue is not flat** (`/tmp/planecheck` over 1000-frame windows of the real
file; the chroma columns in that tool are at **half scale** - it reads video black as
U=V=64 where the 8-bit code is 128 - so the U/V figures below are doubled, and the
same numbers come out of `signalstats` on the file directly):

| window | Y range | U range (8-bit) | V range (8-bit) | mean Y/U/V |
| --- | --- | --- | --- | --- |
| t=100, 2000, 4100 (programme) | 231-240 | 78-120 | 52-212 | 94-113 / 123.2 / 129-136 |
| t=4150 (last seconds of programme, dark) | 94 (min 28) | 164 | 52 | 60 / 184 / 120 |
| t=5000, 6500, 8000 (**the blue**) | 38.0 | 172.4 | 34.4 | 47.4 / 205.9 / 116.3 |
| t=8220 (black hold) | 0.0 | 0.0 | 0.0 | 16 / 128 / 128 |

The blue is a **static pattern, not a flat field**: three windows 3000 s apart score
identically to a tenth of a percent, and its chroma spans 172 codes. It is the
no-signal colour subcarrier beating against the digitiser's sampling clock, so it has
the *spatial* content of real footage and the *temporal* behaviour of a frozen frame.

Which leaves every candidate pixel predicate short except one, and that one is
overwhelming once the chroma scale is right:

* **exact repetition** cannot see it at all — no two frames are identical;
* **temporal calm** separates them in the right direction (blue 0.0199 < the 0.035-0.049
  of the quiet held shot in §12) but with ~20 % of margin either side, and a false
  trigger mid-tape is the worst kind of wrong;
* **spatial contrast** fails outright: the blue's Y range (38) *overlaps* the dark
  final moments of the programme (28-94), and its U range (172) overlaps it too (164);
* **mean colour** is the one that works: at half scale its margin looked like 12 codes
  (U 102.9 against 91.6), but the codes are 8-bit and the real gap is **205.9 against
  123-129 for programme — 77 codes**, on every window of the file and on a live
  s-video feed (2026-11-03: Y 47.9, U 206.2, V 116.4).

**The fix (2026-11-03), and it is a monitor option:** after `PCTV_BLUE_SECS` (default
60) of a frame whose mean is blue and dark (U >= 170, Y <= 110) *and whose three plane
means have not moved by more than 3 codes since the run began*, the monitor closes the
file, ends the run and releases the card — the tape is over. The stability clause is
what keeps a genuinely blue shot out: a sky is Y 150-200 (luma alone excludes it), and
anything that *moves* restarts the window instead of accumulating it. Two live checks
(2026-11-03): a 15 s programme clip followed by the deck's blue ended the run exactly
`PCTV_BLUE_SECS` after the transition, and a 5 s blue insert between two programme
passages did not (the window restarted when the picture came back). It counts only
after a real picture has been seen since the file opened, so a monitor started in
front of a stopped deck does not quit; `PCTV_VERBOSE` prints the means every second so
the predicate can be re-checked against any deck.

What that leaves is still worth knowing:

1. **The rate collapse is 10x separated and `scripts/pctv-autoend.sh` implements it.**
   65 kB/s of file growth for the blue against 700-780 kB/s for the programme. The
   reason the tape ran on for 69 min is that the watchdog was not running, not that
   its predicate was wrong. It is still the fallback for a monitor that does not see
   the pixels.
2. **`PCTV_HOLD_SECS` was 120, and that was wrong in the other direction** — a damaged
   patch of tape is bit-identical too and got its file cut in the middle (2026-11-03).
   It is 600 now. A deck that ends with a 44 s frozen black tail is caught by the
   blue rule at 44 s or by `PCTV_HOLD_MAX`.
3. **Set `PCTV_HOLD_MAX`** for an unattended run if the deck may end in *static*, which
   no pixel rule here sees.
4. **A raw master still has no rate signal at all** - fixed-frame-size output costs the
   same 20.9 MB/s for blue as for programme, so 69 min of nothing costs 87 GB of NAS
   and every byte-rate guard is blind to it. The blue rule is the guard for that case
   (it needs no bit rate, only the picture); `PCTV_MAX_GB` against a *misbehaving*
   deck remains unimplemented.

### Finding where the content actually ends

If a capture did run on, the tail is trivially separable, because a frozen
digitiser frame is **bit-identical** to the next one. Score a short window by mean
absolute inter-frame difference:

```sh
ffmpeg -ss T -t 5 -i FILE -an \
  -vf tblend=all_mode=difference,signalstats,metadata=print:file=- -f null -
# sum the YAVG lines.  live programme: 3.8-9.5.  end-of-tape hold: exactly 0.0000
```

Binary-search that predicate and you have the boundary to the second (two orders of
magnitude of margin, so no threshold fuss) - **provided the tail really is frozen**.
It is not always: the blue no-signal field of §12 above scores 0.0199, nonzero and
*below* a quiet held shot, so an exact-zero binary search walks straight past it. Where
the tail is a pattern rather than a value, find the boundary by the rate (750 to
65 kB/s in the same file) or by the mean colour, which stops moving at all. Do not trust a merely *low* score: a
long 3 min passage at 0.035-0.049 in the same tape was real programme, a still shot
with tape noise in it. Cross-check the picture itself — the end-of-tape hold read
Y=16, U=128, V=128 (video-black, and identical PNG hashes at t=5890 s and t=30000 s)
where the last live frame was Y=42, U=196, V=117.

Trim from the start, so nothing before the cut is re-touched and no re-encode is
needed:

```sh
ffmpeg -i in.mpg -t 5896 -map 0 -c copy out.mpg   # keep 10s of tail for a clean end
```

Then check the copy: both stream durations still equal, `field_order=tt` and
per-frame `top_field_first=1` intact (§10.3 — a copy carries them, but this is the
one tag worth re-verifying), the last frame decodes to the black hold rather than
garbage. A `Header missing` from mp2 on a *seeked* decode is a seek artefact, not
damage: run the same seek against the original and see the identical two lines.

## 13. Where to look

| path | what |
| --- | --- |
| `pctv-linux/TRUTH.md` | **the authority** on hardware behaviour (§2.1 download order, §4 state machine, §6 analog path, §8 retracted claims) |
| `pctv-linux/probe.c` | the userspace driver: vendor request map, `analog2_bringup`, `stream` |
| `pctv-linux/pctv-monitor.c` | BT.656 parser, SDL2 view, capture masters (§10), AGC |
| `pctv-linux/live-module.nix`, `package.nix` | deployment: handoff unit, udev, sysctl, RT limits, firmware, wrappers |
| `pctv-linux/capture-selftest.sh` (+ `fakeprobe.c`) | the capture path's regression harness: real-time synthetic BT.656 with injected URB losses, aligned holes and driver stalls (§14.5) |
| `pctv-linux/replayprobe.c` | the *other* harness: **real tape pixels** (a UYVY file) replayed as real-time BT.656, for the tests `fakeprobe` cannot do because its staircase picture is not a picture — queue depth, sink stalls, byte-identity of a master (§14.2b). `PCTV_PROBE=replayprobe REPLAY_UYVY=… PCTV_NO_SUDO=1 pctv-monitor --capture …` |
| `/ds-public/pctv-masters` (GEN8) | where lossless masters land: 20.9 MB/s, 12.6 GB per 10 min, **151 GB per 2 h tape** — which is why it is a 17 TB pool and not the laptop SSD (§8, §14.2b) |
| `pctv-linux/queue-selftest.sh` | the *sink* half of the regression suite: freeze ffmpeg with SIGSTOP mid-capture and assert (§14.2b) that nothing inside a file is ever lost, that the backlog rides the local-disk spill with zero loss (§14.2g), that a full or disabled scratch file restores the loud early stop, and (§14.2c) that quitting a wedged sink still returns |
| `pctv-linux/avclock-selftest.sh` (+ `avclock-selftest.c`) | the *clock* half: nine simulated tapes through the real producer/commit/controller, asserting exact track equality, bounded-and-repaid phase E, refused catch-up windows and soft seams (§14.2f) |
| `pctv-linux/README.md` | usage, keys, options; and why `driver/` (the V4L2 module) is retired |
| `pctv-linux/COLD-BOOT-NOTES.md` | cold-boot runbook and symptom → cause → fix table |
| `scripts/pctv-autoend.sh` (+ `-test.sh`) | tape-end watchdog and its harness (§12) |
| `docs/pctv-320cx.md` | the superseded Win7-VM route |

**The general lesson:** before writing a kernel driver for a USB device, capture what
the vendor driver actually puts on the wire. If the device is control-transfer + bulk
stream and only one program needs the data, userspace gets you a working product —
faster to iterate, no kernel-version coupling, no `CONFIG_RUST` toolchain, and nothing
to rebuild when the kernel bumps.

## 14. Smoothness: the 2026-11-02 capture rework

Reported symptom, again: *the recording still does not look as smooth as the live
view*, and *SSHing in during a capture makes it stutter*.  Both are true, they
have three independent causes, and only one of them is buffering.

What "smooth" has to mean here: the file is 25 fps interlaced, so its 50 fields a
second are 50 distinct moments.  A recording is as smooth as the live picture
when **every field the card produced reaches the file exactly once, in order, with
no repeats and no evictions**, and when the audio track is the same length as the
video track so nothing has to be stretched at the end.  Everything below is that
sentence, item by item.

### 14.1 Where a field was actually going (measured)

A 300 s capture of live tape, old code: `7515 frames, dup 39, skip 1`, and the
monitor's own anomaly log said the 39 line up with **74 "stale-field feeds"** -
the deframer seeing the same field parity twice, which only happens when a whole
field *never arrived*.  One every four seconds, 0.5 % of pictures, which is a
visible hitch every four seconds.

Only one thing can remove a whole field from a bulk-IN stream: **the host had no
URB posted when the device had data**, and the device's FIFO wrapped.  That is

* invisible - no error, no counter, no short read: the bytes simply are not in the
  stream; and
* tiny - 24 URBs x 32 KiB is 768 KiB, which at 27 MB/s is **28 ms**.  Less than one
  scheduling hiccup on a 2-core Core 2 Duo running kwin, PipeWire and a build, and
  the earlier session measurements had the box at load average 6.5 against 1.15
  cores of demand.

So the fix is not more of our own buffering (there is already 2.4 s in the probe
and 1.2 s in the pipe, which is why `0 stream drops` was being printed the whole
time) - it is **more of the card's**: `PCTV_URBS`, default 128 x 32 KiB = 4 MiB =
155 ms.  Five times the deadline for the scheduler to come back.

### 14.2 Where the rest of the hitch was

Four more things, each cheap once the cause is picked apart:

0. **The frame was being destroyed *after* all that buffering.** `field_commit()`
   assembled each picture into one buffer and set a flag; the **main loop** then
   handed that buffer to the capture queue.  With nothing else going on the loop
   turns over every 17-28 ms, so that was invisible.  But `pump()` reads and
   parses *everything the pipe holds* on each pass, so one slow iteration (a modal
   paint, a page-in, an SSH login, a `sync`) makes it chew through hundreds of
   milliseconds of stream and assemble a dozen pictures - and only the **last**
   one was ever queued.  That is precisely "a fresh picture is lost when the box is
   busy", and it is why deeper pipes never fixed it: the loss happened downstream
   of every buffer.  The frame is now queued **where it is born**, inside
   `field_commit()`, one slot per assembled picture.  The main loop keeps only
   what must not run inside the parser (`cap_start()`, which pumps) and the
   drawing.  Same class of bug as §11's "every frame is queued where it is born",
   one layer further down - and just as invisible without reading the call site.
1. **A USB hole used to cost two whole fields, and it no longer has to.** The
   bytes are gone, but the *lines that survived are not damaged*: BT.656 numbers
   them by content, so the only thing a hole costs is knowing **which row each
   line belongs to** - and that is measurable, from two things the stream does
   carry:

   * the **guard-code pitch**. It is fixed at 1728 B, so a hole that starts or
     ends mid-line shows up as a seam at the wrong pitch, and the pitch says how
     many bytes are missing (a lost 32 KiB URB is 18.96 lines, so it always
     leaves one);
   * the **field length**. Removing N *whole* lines leaves the guard codes
     exactly 1728 B apart - nothing at all to see - but it leaves the field N
     lines short at its end.

   The pitch gives the seam's position, the field length gives the shortfall, and
   `field_commit()` puts them together: everything below the seam moves down by
   `shortfalls` rows and the band is filled from the last clean frame's
   same-parity rows. **A lost URB is now a 19-row band that is 40 ms old, not a
   repeated picture**, and the field keeps its geometry and its place in the
   cadence. The one case no parser can fix is a hole aligned exactly to whole
   lines *and* not followed by a short field (two holes in one field): then the
   shortfall cannot be placed, the field is held and the gate repeats one
   picture - the honest worst case, and it is counted. The exit line prints
   `stream gaps of N B/M rows, K repaired at the seam`.

   A **false** guard code inside active video (0xFF 0x00 0x00 does occur in
   bright saturated pictures) used to look like a hole too, and cost two fields.
   A candidate closer than one full line to the previous real one cannot be a
   line boundary, so it is now ignored and counted (`false sync words`).
2. **The clock cost frames.** Pacing the video on the audio byte count (§11) makes
   the two tracks exactly consistent *and* turns the crystal difference into a
   duplicate or an eviction every 40 ms of accumulated error.  On this box that
   error is **+135 ppm** (measured: 59.328 s of audio against 59.320 s of video in
   60 s), so a hitch every ~5 minutes, forever.  Reversed on 2026-11-02: the card
   is the clock (a queued frame goes out immediately, so the file's cadence is the
   field cadence and no clock difference can evict anything) and the *audio* is
   resampled to the frame count instead - a 0.23 cent pitch shift, and both tracks
   are the same length by construction.  `PCTV_CLOCK=audio` restored the old
   writer for A/B runs until it, and the whole either/or, was replaced on
   2026-11-04 by the coupled commit (§14.2f).
3. **Sync was measured by track *length*, not by tape position.** A duplicated or
   evicted picture advances the file's video timeline 40 ms without 40 ms of new
   content, so every one of them walks the sound out of step with the picture and
   never comes back - 39 of them in 5 minutes (the measurement in §14.1) is 1.5 s
   of lip-sync error with both tracks still the same length.  Now the same 40 ms
   of audio is dropped whenever a picture is repeated or evicted
   (`aq_skip_bytes`), so the two timelines stay locked to one tape position.  The
   stop line reports it separately (`N B cut to match the picture`) so it can
   never be mistaken for a dropout.  [Superseded 2026-11-04: the coupling means
   a repeated picture never owed audio at all, and `cut`/`aq_skip_bytes` are
   gone - see 14.2f.]
4. **The first frame and the first audio sample were not the same instant.**
   `cap_start()` waits up to 2 s for the PCM to come up, and the audio queue was
   already filling during that wait - so a capture started right after launch
   could carry up to 2 s of sound in front of its first picture.  The writer now
   refuses to write audio until frame 0 exists and discards the pre-roll, which
   bounds the offset by one capture period (60 ms) instead.

### 14.2a When the picture is allowed to repeat at all

A repeated picture is not free: it advances the file's video timeline 40 ms for
content that does not exist, so it *is* a 40 ms sync error unless the matching
audio is cut as well (14.2.3, which is why those two ship together).  So the
writer repeats only when it is sure the source itself has stopped, and "the queue
is empty" is not that:

* **nothing queued for >70 ms**, *and*
* **fewer than 4 pictures in the last 400 ms** (a live source puts 10 there), *and*
* **nothing waiting to be parsed** - `FIONREAD` on the probe's pipe plus the
  parse buffer.

The third test is what makes a desktop freeze safe.  The card never stops
streaming (a paused deck still emits fields), so pictures that are not arriving
while *bytes are* arriving can only mean the host is behind - and those pictures
are coming.  Early on this was got wrong in the expensive direction: a 300 ms
stall earned a dozen repeats **and** then the dozen real pictures, which makes the
video track longer than the tape and walks the sound out of step.  A 1 s
`SIGSTOP` of the whole process is now `dup 0, skip 0` with the full picture count
(14.5).

### 14.2b A full picture queue ends the capture — it no longer evicts (2026-11-02)

A 3 h 21 m recording (`pctv-cap-20261102-145124.mpg`) came off the tape with
`skip 59688`: **22 % of its pictures had been silently discarded** to keep a
stalled sink in step, while every headline counter stayed alive. The policy was
`cap_feed_video` evicting the oldest frame whenever the queue filled. That policy
is gone, because the oldest frame is as much of the tape as the newest one: a file
missing a fifth of its pictures, with nothing saying so, is worthless as an
archive and priceless as a mystery.

Now a full queue **stops the capture and says why** (`SINK STALLED`), never
reopens, and counts what arrived after the stop in `refused`. Two outcomes remain:
a complete file, or a short file with a loud reason. The drain that closes the file
also stopped dropping pictures (it used to abandon any frame the sink did not take
within 3 s); it now keeps trying for 30 s plus 100 ms per queued frame and, if it
still cannot write them, prints `LOST PICTURES` with a count and the number of
seconds the file ends early. *(Amended 2026-11-04: a full RAM queue is no longer
the end of anything while local disk is available — it overflows to the spill
scratch file and the take runs on; the stop described here is what still happens
when even the scratch file says no. §14.2g.)*

**Depth is set by ffmpeg, not by the disk.** The queue is 150 frames = 6 s
(`PCTV_VQ_SLOTS`, ceiling `VQ_SLOTS_MAX` 500 = 415 MB; the MPEG-2 path keeps 24),
and 6 s is where ffmpeg's matroska muxer stops being a bystander: it enforces a
**10 s maximum interleaving gap** between streams, and a raw-video input carries no
timestamps of its own, so a video backlog *is* that gap. Past 10 s the muxer stops
reading both pipes — the queue then fills whatever its size, and the stall becomes
a dead capture. That was measured, not reasoned: a 600-frame (24 s) queue plus an
8 MiB (43 s) audio ring — both sized against the wrong model — turned a 12 s
encoder freeze into a muxer that consumed **nothing for 24 s after the encoder
resumed**, because the sound had run 12 s ahead of the picture. Both rings now sit
under the interleave limit (video 6 s, audio 1 MiB = 5.4 s), and the audio rule is
"the ring refuses past half, out loud", not "the ring is infinite".

The write path was never the limit. Measured on this station against GEN8's
`ds-public` (NFS 4.2, `hard`, 1 MiB `rsize`/`wsize`): **123 MB/s** sustained
buffered writes and 107 MB/s with a final `fsync`, against 20.9 MB/s for a lossless
UYVY master — 5-6× headroom, with the client's dirty backlog sawtoothing around
600 MB without ever stalling the writer.

What the depth buys, measured by freezing ffmpeg with `SIGSTOP` mid-capture (the
harness is `pctv-linux/replayprobe.c`: real tape pixels, real BT.656 pacing, so
nothing about the deck or the card can excuse a loss):

| sink freeze | old queue, 6 slots | 150 slots, no eviction |
| --- | --- | --- |
| 3 s | 953 frames written, `skip 60` — 60 pictures gone, file kept growing | 1524 frames, `dup 0 skip 0 refused 0`, video PTS contiguous at 40 ms |
| 12 s | (silently evicted for as long as it took) | `SINK STALLED` at 6 s of cushion; 372 frames written = 372 packets, PTS contiguous, `refused 1` |
| none, 10 min | — | 15001 frames, `qmax 1/150`, 0 video drops, 0 audio drops, 12.56 GB, `refused 0` |

*(The middle row is history: since the local-disk spill, §14.2g, a 12 s freeze no
longer stops anything — the 150-slot queue is now only the first 6 s of cushion,
not the whole one.)*

The acceptance test for a change in this area is *not* `skip == 0` (a probe-ring
byte eviction shows up as a stream gap, not a skip) — it is **frames written ÷
elapsed × 25**, plus contiguous video PTS.

### 14.2c Quitting was the same circular wait, one stage further down

The 2026-11-02 lockup (press stop, monitor never returns) was diagnosed as
`child_stop()` waiting on the probe behind a writer wedged on a full pipe, and that
half is fixed. Building `queue-selftest.sh` found the rest of it, in three places:

* **`cap_stop()` blocked forever on its own child.** It gave ffmpeg 10 s to finalise,
  then `kill(SIGTERM)` and a **blocking** `waitpid`. A *stopped* process does not
  receive SIGTERM — the signal is queued until it is continued — so the wait never
  returned. Now: TERM, `SIGCONT`, bounded 3 s; KILL, `SIGCONT`, bounded 3 s; then walk
  away and say so. A zombie gets reaped when the monitor exits; nothing on a shutdown
  path is worth an unkillable monitor.
* **The drain waited out its own grace on a dead sink.** The queue-full stop added a
  30 s + 100 ms/frame drain deadline (§14.2b), which is right for a *stall* and looks
  identical to the lockup when the operator presses stop. Two different waits now:
  a stall nobody walked away from keeps its grace and delivers its backlog (measured:
  274 pictures including everything queued during a 12 s freeze), while **a quit
  discards the queue after 3 s of not one more byte** — in one decision, not a frame
  at a time (148 frames × a 3 s `pipe_write` timeout each would have been 7 minutes).
* **`LOST PICTURES` is printed when the drain does discard**, with the count and the
  seconds the file ends early, and the audio is refused (`aq_closed`) at the same
  moment so the ALSA thread cannot refill a ring nobody drains — the original 50 s
  shutdown hang.

Measured with the same `SIGSTOP`-the-encoder harness, after the fixes:

| case | result |
| --- | --- |
| 3 s freeze, capture runs to its deadline | `dup 0 skip 0 refused 0`, 525 pictures, PTS contiguous; quit 0 s |
| 12 s freeze (longer than the queue) | `SINK STALLED`, 274 pictures delivered including the backlog, PTS contiguous, `refused 1`; quit 1 s |
| **quit pressed while the encoder is frozen** | **gone 6 s after SIGTERM** (was: never) |

It is in the repo as **`pctv-linux/queue-selftest.sh`** — three cases, the same
assertions, run it after touching anything in the capture path.

One more number that was lying: the `ADC +/- ppm` drift figure is *audio fed to the
resampler* over *pictures written*, so during a sink stall the denominator stops and
a stalled pipeline is reported as a **4 % crystal error** (measured `+42362 ppm` and
climbing through a 12 s freeze; the old unit bug in §14.5's note pushed it to the
`+50000` clamp). `rs_update()` now holds its last good step while `vq_backlog` is set,
and `queue-selftest.sh` fails if any drift reading reaches five digits.

> Superseded on 2026-11-04: the freeze was treating a symptom. A windowed measurement
> cannot be fooled by a stall in the first place (a window with no pictures in it is
> skipped), and freezing on queue depth was itself costing minutes of uncompensated
> drift on NFS. See §14.2d, and `avclock-selftest.sh`, which now asserts both.

### 14.2d The sound was a second behind the picture and every counter said zero (2026-11-04)

`pctv-cap-20261104-015210.mkv` plays with the sound more than a second late. Not at
the start - by the end. Every counter in its stop line was the same as a clean take,
because not one of them measured what the two tracks disagreed by. Checking the eight
masters on `ds-public` showed it was never one bad take:

| master | video | audio | audio − video |
| --- | --- | --- | --- |
| `Disney Paris` | 8260.120 s | 8260.006 s | −0.114 s |
| `Disney` | 7390.360 s | 7390.816 s | +0.456 s |
| `France July 96 No1` | 5401.440 s | 5402.313 s | +0.873 s |
| `Portugal Spain on Plane` | 4890.800 s | 4889.697 s | −1.103 s |
| `France 1997` | 4199.720 s | 4201.192 s | +1.472 s |
| `Portugal Spain` | 6644.960 s | 6646.462 s | +1.502 s |
| `pctv-cap-20261104-015210` | 7294.960 s | 7296.143 s | **+1.183 s** |
| `Portugal Spain (continued)` | 363.600 s | 370.107 s | **+6.507 s** (1.8 %) |

Both signs, no clean pattern, and the two short takes worst. Four separate faults
were involved, and each one on its own looked like a ppm figure rather than a bug.

**The resampler's output was never used.** `rs_run()` interpolates into `rs_buf` and
returns a count; `cap_feed_audio()` then set `n = nout * 4` and did `memcpy(aq + tail,
p, first)` — from `p`, the *input*, with the length computed for the *output*. Nothing
in the program ever read `rs_buf`. So the design in §14.2.2 (a ~135 ppm resample,
inaudible, holding the tracks together) never reached a tape: what the masters carried
was the raw ADC bytes with the tail of a block deleted whenever the step was above 1 —
a hard sample discontinuity roughly 24 times a second at 450 ppm, i.e. a crackle
riding on the sound and a sound that steps forward in time — and whenever the step was
below 1, a copy of up to ~400 B *past the end of the audio thread's 4096-byte buffer*
(stack, whatever it held) into the middle of the tape's audio. A pitch shift that is
never applied, paid for with sample-dropping instead.

**A ratio cannot see how far behind it is.** `rs_update()` divided *audio fed to the
resampler* by *samples the pictures written owe*. That answers "how fast should I go"
and never "what do the two tracks already disagree by", which is the whole of a
lip-sync error. Any loss of sound — an ALSA overrun (`snd_pcm_recover()` drops the
samples and says nothing), a device reopen, a PipeWire graph restart, the audio thread
simply not being scheduled — leaves the sound shorter than the picture *permanently*,
and the only thing the ratio could do was stretch the rest of the tape to cover it.
That is the mechanism of the report: a hole at any point becomes a slow error that
never comes back. The log proved the controller was measuring something other than a
crystal: `A/V clock` drifted monotonically `−72 → −527 ppm` across one take's first
minutes and then snapped back (`−487, −396, −163`) the moment the picture queue filled,
it sat at `+447 ppm` in the next take, and the run reached `−1203` and `+11689 ppm`.
A crystal is 100–500 ppm (§11 measured 135); the rest of that number was the phase
error nobody was acting on.

**The cut was charged twice.** `owed -= rs_skipped_frames` told the controller that
samples deliberately *not kept* still had to be replaced, so it squeezed the remaining
sound to make them up: sound walking ahead of the picture. That is why `Portugal Spain
on Plane` ended 1.103 s *short* having cut 1.28 s with `dup 0, skip 0` — the cut is
supposed to move the sound along the tape, not to shorten the track it travels on.

**Queue depth froze the clock for minutes.** `vq_backlog` means "more than a quarter of
the picture queue is waiting" — with 150 slots that is 37 frames, 1.5 s of sink stall,
which a lossless 20.7 MB/s write to NFS exceeds routinely (`qmax 109/150` on
2026-11-03). Every second the queue stayed deep, the estimate was frozen and the drift
was added to the file rather than corrected. Which way the error went on a given take
depended on how much of that take the queue spent deep — the table's scatter, in one
line.

**What it does now.** Four changes, all in the audio path and none of them touching a
picture:

* `cap_feed_audio()` queues `rs_buf`, the interpolated samples it always claimed to.
  That fixes the over-read, the sample-dropping crackle, and makes the ppm figure
  finally describe something real.
* `rs_update()` measures over a **window** (input against what the pictures written in
  that window owe) and then adds a **phase** term: `E = what the file owes − what the
  resampler made`, and the step consumes input at the flow rate *and* spends
  `RS_DRAIN_S` (120 s) paying `E` off. With `E = 0` it is the old measurement; with a
  hole in the sound it walks the tracks back onto each other instead of leaving the
  debt. The whole step is bounded to `RS_PPM_MAX` (3000 ppm = 3.5 cents — 6× the worst
  crystal this box has ever shown, and under what anyone hears on speech), so paying an
  error back is never more destructive than the error: a 1.2 s hole takes ~7 minutes to
  unwind and not one second of it is audible. A window whose flow reads further than
  `RS_FLOW_MAX_PPM` (5000) from the card is not a crystal, it is the pipeline, and it
  is discarded and counted instead of believed.
* **PCM holes are filled with silence where they happen.** Two counters in the ALSA
  thread — audio time delivered against wall time since the same anchor, in
  microseconds, because a 21.33 ms block rounded to 21 ms invents 15 ms of hole every
  second — and when the difference reaches one ALSA period (`A_GAP_MIN_MS` 60 ms) the
  missing time is written as silence, faded over 2 ms at both edges so the hole does
  not click, capped at 2 s. The sound that survives stays exactly on the picture, the
  gap stays where the gap is, and the stop line says what it cost.
* The accounting is honest in both directions: samples produced and thrown away (the
  pre-roll discarded before frame 0, PCM evicted from a full ring) are *owed again*;
  silence that reached the file without being sampled *reduces* what is owed; the
  deliberate cuts cancel, and `rs_cut_frames` is reported but never paces anything.

**What to read on a finished take.** The stop line gained four figures, and one log
line exists that did not:

```
A/V phase: the sound is 812 ms behind the picture (paying it back at -3000 ppm)
capture stopped: … 938821828 B audio (245760 B cut to match the picture, 120480 B
  silence for 4 PCM holes), 0 video drops, 0 audio drops/0 B, 3 xruns,
  ADC +447 ppm vs the card, A/V phase +14 ms, 2 clock windows discarded)
```

`A/V phase` at the end is the lip-sync error, in milliseconds, and above 100 ms the
monitor says so out loud. `silence for N PCM holes` is sound the ADC lost: the picture
is still true to the tape, and the number says how much of the tape is standing in for
sound that is not on the source.

**Prove it without a deck:**

```sh
pctv-linux/avclock-selftest.sh          # add -v for the controller's own decisions
```

It `#include`s `pctv-monitor.c`, so it drives the shipping `rs_reset`/`rs_run`/`rs_update`
through simulated tapes with time driven by hand — a 2 h tape in milliseconds:

| case | audio − video | resample |
| --- | --- | --- |
| 2 h, ADC +450 ppm, nothing else wrong | 0 ms | +438 ppm (the crystal, correctly) |
| 2 h, ADC −500 ppm | 0 ms | −500 ppm |
| 2 h, 200 ms PCM hole every 6 min, filled | 0 ms | 3600 ms of silence, at the holes |
| 2 h, same holes, filler not there | +3 ms | the phase term paid 4 s back |
| 2 h, 500 ms hole at 20 min, missed | 0 ms | peak 2281 ppm, inside the bound |
| 2 h, 12 s sink stall | 0 ms | bounded (this used to read +42362 ppm) |
| 6 min, flow reads +18000 ppm | reported, not smeared | 0 ppm: 356 windows discarded as not-a-crystal |

### 14.2e Repairing a master that is already out of step, without re-capturing (2026-11-04)

The capture is fixed for takes from today on, but the masters already on `ds-public`
still have it, and **the lag grows**, so the two obvious repairs are both wrong. A
single shift (`-af adelay`) is right at one instant and wrong everywhere else. A
single tempo change - a shift's other form, `-af asetrate=48000*1.000162,aresample=48000`
for the Cotswold take's 162 ppm - assumes the drift was linear in time, and it was
not: the rate tracked how long the picture queue spent deep (§14.2d), so it wanders
inside one take and changes sign between takes. The tool for the existing files is
`scripts/pctv-desync-repair.sh`.

**What works is a piecewise tempo correction.** Measure the lag at a handful of
timestamps, treat it as piecewise linear between them, and give each span the tempo
that loses exactly the drift that span collected:

```
new[p] = old[p + d(p)]            factor = (L + drift) / L
```

A 1200 s span shedding 195 ms plays at 1.000163: 163 ppm, 0.28 cents - the same
inaudible order of resampling the capture path already does by design (§14.2.2).
Nothing is cut out of the middle and nothing is spliced, so there are no clicks and
no lost content; the sound is *stretched*, it lands exactly on the picture at every
anchor, and between anchors it is off by less than the anchors are apart. Only the
front `d0` ms is dropped, which is sound from before the first picture.

Two implementation traps, both hit here:

- **Not `atempo`.** It is WSOLA; at 1.0002 it does arithmetic the signal does not
  need and can breathe on sustained tones. Plain resampling does this exactly.
- **`asetrate` takes an *integer* sample rate**, so at 48 kHz its tempo granularity
  is 1/48000 = 20.8 ppm - 25 ms over a 20-minute span, which is most of the error
  being repaired. Every span therefore goes up to 480 kHz first, is reinterpreted
  there (1.04 ppm granularity) and comes back: 0.3 ppm measured, under a millisecond
  over a 1200 s span.

### The procedure

1. **Measure.** `--clip OUT.mp4 T FILE [NUDGE_MS]` cuts a 12 s preview at picture
   time `T`; the master seeks instantly (its cues), so this is seconds. `NUDGE_MS`
   moves the clip's audio to test a guess - positive moves the sound *earlier*,
   which is what a late sound needs - so an anchor converges in two or three cuts:
   nudge 600 and it is still late, nudge 1200 and it is early, the truth is near
   900. Write the table down as `picture_seconds:ms_behind`. Keep the clips on
   `/tmp`, never on `ds-public` (§12.3). Take an anchor every 15-20 min, and one at
   the very start and the very end.
2. **`--plan FILE "P:MS,..."`** prints the spans, the source window each one reads,
   the factor and the ppm, and writes nothing. Read it: a span asking for more than
   ~3000 ppm means two anchors are too close or one was mis-measured, and the script
   refuses to go on. The total removed must equal the measured end lag.
3. **Fix the audio, not the master** - `--audio fixed.wav FILE "P:MS,..."`. It reads
   the master once (its PCM is interleaved with 152 GB of video, so that read is
   unavoidable) and writes 1.4 GB. Then let the encode you were going to do anyway
   carry it: `ffmpeg -i master.mkv -i fixed.wav -map 0:v:0 -map 1:a:0 -c:v <encode>
   -c:a pcm_s16le out.mkv`. `--remux` will instead rebuild the master with the video
   stream-copied - bit-identical frames - but it reads *and writes* the whole 152 GB,
   so it is for when you truly want the master back in step, not for the delivery
   copy. `--from WAV` reuses an audio extract already made; `--to S` forces the track
   to the video's length (default: the master's video duration tag).
4. **Verify.** Re-cut an anchor clip from the output and check the lag reads 0 there
   (`--clip` with no nudge), then `scripts/pctv-verify-master.sh`, which now reports
   the tail difference signed and in ppm (§14.2d).

The anchors for the Cotswold take (`Cotswold ⁄ Holidays ⁄ Chris in School at
Christmas.mkv`, 1.183 s late at the end, 162 ppm average) are not measured yet - the
four spread clips in `/tmp/synccheck/` are the starting points. Note that the drift
measured *inside* that take is what decides the span table; the 162 ppm average is
only what its two track lengths imply, and it is not the repair.

### 14.2f One clock, one commit: the coupled A/V writer (2026-11-04)

§14.2d ended with the design reversed (the card is the clock, the sound is
resampled to it) and that was necessary but not sufficient. Two takes on the
same afternoon as that diagnosis said so.

**The take that stopped early.** `pctv-cap-20261104-122137.mkv` ended by itself
after 3827.88 s (63.8 min of a 2 h tape). Every suspect died on evidence: the
stillness detector (content was moving at the cut point - exonerated), a
duplicated-frame storm (a full-file framehash scan: zero consecutive identical
frames), disk full, suspend, OOM, `PCTV_CAPTURE_SECS`, NFS *server* errors - all
no. What the log did show is the §14.2b path firing as designed: writes to
`/ds-public` fell below the ~20 MB/s a UYVY master needs, the 150-slot
(6 s) picture queue filled, and the monitor ended the capture rather than
evict pictures. That is the correct behaviour of §14.2b, not a new bug; if it
recurs, look at GEN8 load and network during captures, not at the monitor. Its
audio track ended 384 ms *before* the video - the same chronic disease as the
next paragraph, read at the tail.

**A second of sound, lost from the middle of the story.** §14.2d's +1.183 s
took a repair script; this take arrived with its sound about a second *early*,
and again no counter complained. The mechanism was structural: the writer paced
the audio on **wall clock** while pictures committed from behind the picture
queue, so every second of queue depth was permanently paid for by the file's
sound sitting that much ahead of the lips of the pictures still waiting to be
written. A chronically 1 s-deep queue (normal on NFS to `ds-public` - qmax
reaches 109 of 150) is a chronic 1 s lip error that track lengths cannot see,
because both tracks advanced at the same real-time rate - together, and one
second away from the picture that owns the sound.

**The fix is the coupling, not a measurement of it.** A commit is now one
829440 B picture followed by exactly 40 ms of sound (1920 frames / 7680 B),
written to ffmpeg's two pipes in that order, by the writer thread, and **no
other path in the program appends to the audio pipe**. Sound leaves the ring
only inside a commit, so a diverged pair is not discouraged - it is not
expressible. Track equality is now exact rather than within-tolerance, and
`scripts/pctv-verify-master.sh` checks it that way (±0.06 s, symmetric). A
chunk that stalls in the pipe holds the *next picture* back, so a sink stall
costs queue depth (and, past 6 s, the §14.2b capture-stop) but never divergence.

What that let the rest of the design become:

* **The ring holds raw ADC frames again** and resampling moved to the drain
  (`a_make_chunk` → `rs_run_into`/`rs_pad_into`). Producers just write bytes
  as they arrive; every consumer-visible number is now in the file's time.
* **Two backlogs, one number.** `E = queue_ms - ring_ms` is the live lip error:
  queued pictures own the ring's oldest sound, and anything the ring holds
  beyond the queue's share is ahead of the lips. A sink stall deepens both at
  the same 1000 ms/s and E does not move; a hole moves exactly one. E is what
  the overlay (`card clock +135 ppm ph +0 ms`), the `PCTV_VERBOSE` line
  (`ring %dms ph %+d`) and the stop line report, and what the resampler spends
  itself draining over `RS_DRAIN_S` 120 s within ±3000 ppm.
* **The crystal is measured over arrivals only** (`aq_raw_frames`), because
  since the coupling the drain *is* the resampler - reading consumption back
  would wire the instrument to its own output. A window that reads more than
  ±5000 ppm is the pipeline, not a crystal (the 12 s SIGSTOP of §14.2d
  measured +42362 ppm that way), is discarded, and counted as
  `clock windows discarded`. The first good window **seeds** the step outright;
  blending even 2 %/s from 1.0 left a ~50 s ramp in which a cold −300 ppm ADC
  starved the drain for 16 ms of invented silence in an otherwise clean take
  (the self-test found this too, and the cold-start residue is now < 2 ms).
* **The 4 MiB (21.8 s) ring cannot make the muxer miss its 10 s interleave
  ceiling any more** - not by being smaller, but because the ceiling only ever
  applied to streams moving independently.
* **Every seam is soft**, on the standing order from SaLou: a detected hole's
  zeros ramp *into* the ring at the gap (`cap_feed_silence`); a hole caught
  late lags by its length, E sees it, and the step pays it back; an undetected
  one starves the drain, which pads (`rs_pad_into`, now counted as
  `… B padded at the drain` in the stop line). The fade-down and fade-up are one
  continuous gain envelope (`rs_gain`, fixed 1/96 per frame) - the self-test's
  click scan found two real bugs on the way (the fade reading a source it had
  already zeroed shipped `[last, 0, 0, …]` = 1079 units against a 209-unit tone
  slope, and a short pad's too-fast re-arm stepped 1248 units).
* **Frame 0 keeps exactly the queue's own sound.** Everything older is
  pre-roll (captured before the file's first picture existed) and is dropped -
  but clearing the *whole* ring also destroyed the sound belonging to pictures
  already queued at frame 0, the one misalignment E structurally cannot see.
  And the keep is queue+1: the frame being committed is `vq_held`, not
  `vq_count`, and dropping its 40 ms put a soft pad and a half-frame lip error
  at the head of every take.

`pctv-linux/avclock-selftest.c` grew into the gate for all of it: nine simulated
tapes (both crystals over 2 h, a 12 s sink stall, a hole caught on time, one
caught late, one caught never, a deck pause, the chronic-deep-queue regression)
driven through the real producer, real commit and real controller, asserting
track equality *exactly*, E bounded and paid back, the step settling on the
injected ppm, catch-up windows refused, and no sample-to-sample step over 800
anywhere in the recorded audio. `./avclock-selftest.sh` - fast, and the first
thing to run after touching anything in the commit machine.

### 14.2g The queue now overflows onto local disk, so a slow NFS sink ends nothing (2026-11-04)

§14.2b left one honest hole in the design: the queue was the *only* waiting room,
so a sink slower than the tape for longer than 6 s still ended the take. That is
the case this rig actually runs in — a lossless UYVY master is 20.9 MB/s onto
GEN8's `ds-public` over NFS, and §14.2b's own measurement says the write path has
5-6× headroom *sustained*. Nothing about the sustained figure describes the bad
minute: a resync on the pool, someone's `scrub`, a snapshot window, and the
sink drops under real-time for longer than any queue made of RAM can be.

Pictures were never the scarce resource — RAM is. So the queue now has a second
stage behind it: **when the RAM queue cannot take a pair, the pair is appended to
a scratch file on the capture host's own SSD**, and it walks back into the writer
path the moment the writer asks for one. The capture ends only when even the disk
says no, which is the §14.2b stop unchanged and still correct: it now means the
host itself is out of room, not that NFS had a bad minute.

Three things had to be true, and each of them is a fact about this design rather
than a taste:

* **A record is a PAIR.** The 64-byte header says how many bytes of sound follow
  the 829 440 of picture; the sound is that picture's own exposure window, cut off
  the **tail** of the ring at spill time. Spilling pictures alone would commit the
  wrong sound to the wrong picture the moment the backlog outlived the 21.8 s
  ring — which the chronic-slow case does in minutes — and that is exactly the
  damage §14.2f exists to make impossible. At restore time the bytes go **in
  front of** the ring (the `rs_front` stub), so `a_make_chunk` still reads one
  contiguous capture-order stream and never reorders the sound.
* **The audio part is variable, and short is not an error.** While the file holds
  records, ALSA delivery and per-arrival extraction cancel, so the ring settles at
  a few ms and a record's tail is whatever the ring could actually pay. Zero-
  padding a short window into a fixed one would splice silence into the middle of
  the sound; a truncated record the drain pads *softly* (the `rs_pad_into` seam
  the clock already knows) is the honest shape — and the deficit is bounded by the
  crystals, about a sample.
* **Ordering is by position, and that costs a routing rule:** while the scratch
  file holds a backlog, **every** new pair goes to the file, room in RAM or not
  (`cap_feed_video`). RAM then holds one contiguous OLDER block, the file one
  contiguous NEWER one, and "oldest pending" is a fact about positions. Without
  the rule a newer frame could re-enter RAM while older ones sat on disk, and the
  writer — which must pop RAM first because that is what the audio stream
  requires — would commit it before them.

The clock does not see any of it: each record is one pending picture (queue side,
`sp_count × FRAME_MS`) *and* that picture's own sound (ring side, `sp_sound`), so
`E = queue_ms − ring_ms` grows by the same amount on both sides and cancels.
`rs_update` charges both terms explicitly; charge one and forget the other and the
controller would chase an invented lip error into the audio.

Disk discipline, because the spill must never become the new way to lose a tape:
`mkstemp` then **immediate unlink** (a crash leaves no file, and space returns the
instant the fd closes), `posix_fallocate` in 64 MiB chunks so ENOSPC surfaces
before a picture is lost rather than in someone's writeback, a cap of
`PCTV_SPILL_MB` further clamped by the measured free space at activation minus a
1 GiB floor, and `PCTV_SPILL_DIR` **must be local** — spilling onto the same slow
mount is circular. The producer's hot path is one memcpy plus one bounded
`pwrite`: no retries, and nothing that waits on the sink.

The two failure directions are deliberately asymmetric:

| | what happens | why |
| --- | --- | --- |
| **append fails** (cap, ENOSPC, `pwrite` error) | `SPILL FAILED`, the file **keeps its fd and every valid record**, the drain restores them, and only the picture that could not be written ends the capture | nothing already recorded becomes a hole over a disk error |
| **read-back fails** (bad header, short `pread`, stub overflow) | `SPILL FAILED`, then §14.2b verbatim: count everything still owed, end the take complete to the last pair really in the file | two swapped segments of sound are exactly the damage class this file refuses to commit; reordering to keep pictures would be a worse loss than losing them |

`spill %llu` in the stop line counts the pairs that went to disk this take;
`spill done:` says the sink caught up and the capture is running from live again.
A healthy long take with a healthy sink shows `spill 0`.

Measured with `queue-selftest.sh` (12 s SIGSTOP on ffmpeg — twice the RAM queue —
against the SSD scratch file):

| case | result |
| --- | --- |
| 12 s freeze, spill on (default) | `SPILL ACTIVE` at 6 s, 179 pairs to disk, `spill done:`, then `dup 0, skip 0, refused 0, spill 179`, 499 pictures, video PTS contiguous at 40 ms, `A/V phase +0 ms` — **the take is untouched** |
| 12 s freeze, `PCTV_SPILL_MB=0` | the pre-spill design exactly: `SINK STALLED`, 263 pictures, `spill 0`, file complete, PTS contiguous |
| 12 s freeze, `PCTV_SPILL_MB=64` | `SPILL ACTIVE`, 80 pairs (64 MiB) in, `SPILL FAILED (cap)`, capture ends with `dup 0, skip 0, refused 1, spill 80`, 343 pictures, PTS contiguous — everything recorded is in the file |
| 3 s freeze, spill on | never touches the scratch file at all (`spill 0`): RAM absorbs it, as before |

Sizing: 64 MiB of scratch holds 78 pairs ≈ 3 s of master; the default 32 GiB cap
is ~25 min of chronic ~16 MB/s sink, and a 90-min tape that stays behind all the
way wants ~33 GB — so the cap *firing* is documented behaviour, not a surprise,
and `PCTV_SPILL_DIR` wants a disk with room if that is the workflow.

### 14.3 The system tuning that keeps the deadline

All of it in `pctv_probe` at stream start (it is root, and it is the only stage
that destroys data when it is late); all of it restored on exit; `PCTV_TUNE=0`
turns it off.

| what | why |
| --- | --- |
| `usbfs_memory_mb` -> 64 MiB | the kernel's budget for *all* pinned URB memory is 16 MiB by default; 128 URBs need 4 MiB of it and a refused submit silently narrows the pipe |
| `/dev/cpu_dma_latency` = 0 | pins the package out of the deep C-states; exit latency is hundreds of microseconds and this is what "SSHing in stutters it" looks like from the CPU's side |
| cpufreq governor -> `performance` | one governor for all CPUs, remembered and restored; `ondemand`/`schedutil` spends milliseconds ramping up |
| `mlock` + pre-fault | 64 MiB stream ring, 4 MiB of URB buffers, 20 MB of frame queue, 1 MiB of audio: a first-touch page fault in the producer is a stall in the one place there is no cushion. The monitor's half is `mlock`ed under the `memlock` login limit `live-module.nix` sets for `@wheel` |
| `SCHED_FIFO` (probe 10; monitor writer 9, ALSA reader 9, parser/renderer 8; ffmpeg none) | the 2026-11-01 work (6fdd651) - this is what stops the desktop from being able to preempt the path at all, and the deeper URB pool is what stops a 100 ms kernel excursion from mattering anyway. The intra-monitor split is new: SCHED_FIFO threads of equal priority never timeslice, so the two that own a producer's ring sit above the one that draws, which is the only one of the three with seconds of cushion behind it. The ALSA reader's whole cushion is one 60 ms period and an overrun there loses *samples*, which no ring can give back |

### 14.4 Playing it back is half the complaint

A 25 fps interlaced file shown as 25 whole frames a second has already lost half
its motion, however perfect the capture.  The live view shows 50 fields a second
because it is redrawn on each field.  Compare like with like:

```sh
mpv --deinterlace=yes '--vf=bwdif=parity=tff' FILE      # 50p, one field per output
ffplay -vf bwdif=mode=send_field:parity=tff FILE
```

`send_field` (the default) is the operative part.  Anything that blends or shows
one field per frame - including VLC's default "automatic" on some builds - will
look like the old, less smooth capture no matter what the file contains.

### 14.5 How to tell whether a run was clean

Run with `PCTV_VERBOSE=1` (or read `$XDG_STATE_HOME/pctv-monitor.log` when it was
launched from the menu) and judge it by these numbers, in this order:

| line | clean | what a bad value means |
| --- | --- | --- |
| `stream: 128/128 URBs x 32768 B` | all submitted | fewer: a submit was refused (`usbfs_memory_mb`) |
| `max gap between completions` | < 5 ms | > 10 ms means the host was away from the endpoint; the device may have dropped data. The probe logs each event with a timestamp |
| `stream gaps of N B/M rows, K repaired` | small, and every `G` has a `g` | a `G` without a `g` is a held field (see 14.2.1); a rising `N` is the USB path asking for more `PCTV_URBS` |
| `dup` | 0, or a handful over hours | the *source* stopped delivering for >70 ms **and** nothing was waiting in the pipe: check the probe's late events first |
| `skip` | 0 — the counter is now a bug detector, nothing more | it used to mean "the encoder could not keep up, oldest picture evicted". That policy is gone (14.2b); any nonzero `skip` is a defect |
| `refused` | 0 | pictures that arrived after the queue filled **and** nowhere could put them, so the capture was ended on purpose (`SINK STALLED`, or `SPILL FAILED` first if the scratch file was what broke). Since the spill (§14.2g) a nonzero `refused` means RAM *and* the local disk were both done. A nonzero `qmax` in the same line (e.g. `qmax 148/150`) says the sink was behind: check the mount, then the master format |
| `spill N` | 0 on a healthy sink | pairs (picture + its sound) that waited on the local-disk scratch file and came back. Any `N` with a `spill done:` line and `refused 0` is the design working: a slow NFS minute cost the take nothing. No `spill done:` and the take ended → the scratch file filled or failed; read the `SPILL FAILED` line for which |
| `qmax N/150 frames` | ≤ a handful | the deepest the picture queue ever got. Near the depth means the capture stopped because the sink was slower than the tape, not because the tape ran out |
| `B padded at the drain` | 0 | sound the *file* needed and the ring could not cover - an **undetected** PCM hole (a detected one reads in `silence for N PCM holes` instead). Every padded stretch is ramped in and out, so it costs audio, never a click; more than a few hundred ms says sound vanished without the gap detector noticing |
| `ADC +/- ppm` | stable, |x| < 500 | the correction being applied, not an error: the crystal difference, now measured over a 1 s window instead of since the start of the take. It is bounded to 3000 ppm because resampling harder than that would be audible, and a window reading more than 5000 ppm is discarded as not-a-crystal (a stall, a reopen, a device that stopped) and counted in `clock windows discarded` instead of believed |
| `A/V phase +/- ms` | inside ±20 ms at the end | **this is the lip-sync error**, in milliseconds, and it is the number that was missing on 2026-11-04: a 2 h take finished 1.183 s out of step with every other counter reading zero (14.2d). Over 100 ms the monitor says so at stop. Watch the *tail* of a take, not the head - the error accumulates |
| `silence for N PCM holes` | 0, or a few hundred ms over hours | sound the ADC lost (overrun, reopen, PipeWire restart, the audio thread not scheduled) and the monitor stood in for, at the instant it went missing. The picture stays true to the tape; this is what the tape is missing. Unfilled, those holes used to be paid for by stretching the rest of the recording - that was the second of desync |
| `xruns` | 0, or a handful over hours | ALSA said the overrun out loud; each one is also a `PCM hole` and filled with silence |
| `clock windows discarded` | 0, or a couple over hours | windows too far off the card to be a crystal. A large number means the pipeline, not the clocks - read it with `A/V phase` |
| video vs audio stream duration | **equal to well under a frame**, both directions | since the coupled writer (14.2f) the two tracks advance 40 ms together or not at all, so *any* difference over ~0.06 s means the coupling leaked - a path that writes audio outside a commit came back. `pctv-verify-master.sh` enforces this symmetrically; `A/V phase` in the log is the same clock's live reading before the file is even closed |

**Or prove it without a deck:**

```sh
pctv-linux/capture-selftest.sh          # add -v for the anomaly timeline
pctv-linux/queue-selftest.sh            # sink damage (SIGSTOP of ffmpeg)
pctv-linux/avclock-selftest.sh          # the clock: crystal, PCM holes, stalls
```

It builds `pctv-monitor` and `fakeprobe` (a stand-in for `pctv_probe stream`
that emits real-time BT.656 in exactly this card's line layout), runs four
captures - clean, one lost 32 KiB URB, a hole aligned to whole lines, and a 1 s
`SIGSTOP` of the driver - and asserts the same counters listed above. It is the
harness the whole of §14 was developed against, and it fails loudly if a change
ever starts costing a picture again:

| case | what it checks |
| --- | --- |
| clean 12 s | 299-335 pictures written, `dup 0 skip 0`, nothing held |
| one lost 32 KiB URB, mid-line | `dup 0`, no short field, one `repaired at the seam` |
| 19 aligned lines dropped | `short 1`, `held 1` - the undetectable case, held rather than sheared |
| 1 s `SIGSTOP` of the monitor | `dup 0 skip 0`, full picture count: the loop was away, the data waited, nothing was repeated |

### 14.6 The one assumption this makes

The audio is fitted to the *picture's* clock, so it inherits whatever the deck does
to the field rate: if a VCR played a tape 0.5 % fast, the picture would be 0.5 %
fast and the audio would be resampled 0.5 % to match (8 cents - audible on music,
irrelevant on speech, and physically correct: both are on the same capstan).  A
VCR's servo holds the field rate to ~0.1 % anyway, and the alternative - letting
the picture hitch to protect a pitch nobody can hear - is the wrong trade for a
picture archive.  The alternative `PCTV_CLOCK=audio` offered was retired on
2026-11-04: with the coupled commit (§14.2f) there is no longer a second
mode - the sound is written *with* each picture, and the resampler ratio is
what spends the crystals' disagreement instead of a mode switch.

