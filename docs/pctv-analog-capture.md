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

## 10. Capture masters, field order, and getting 50p

A capture is 25 frames/s of **625/50 interlaced** video — 720×576, 4:2:2, 50
fields/s. Every choice in this section follows from that: the card already hands
us 50 temporally distinct images per second, so the only questions are what gets
written and what happens later.

### 10.1 The three masters (`--master`, `PCTV_MASTER`)

| mode | container / codec | disk rate | encoder, measured¹ | for |
| --- | --- | --- | --- | --- |
| `dvd` (default) | MPEG-PS, `mpeg2video` `-b:v 6000k -g 15 +ilme+ildct` | ~0.7 MB/s | 4.5× realtime | burning, watching, keeping years of tape cheap |
| `uyvy` | Matroska, `rawvideo` (uyvy422) | 20.7 MB/s (1.2 GB/min, ~35 GB per tape) | 8.0× | **the bit-exact master**: the deframer's own bytes, no colourspace conversion, no rate control |
| `ffv1` | Matroska, `ffv1 -g 1` (yuv422p) | content-dependent: 0.1 MB/s on a noiseless test pattern, a few MB/s on grainy tape | 2.7× test pattern | the same bits at a fraction of the disk, for the price of a real encoder |

¹ ffmpeg's own `speed=` with every mode fed the *same* raw UYVY the capture
pipeline produces, so the figures are comparable; >1× means it keeps up. FFV1's
cost tracks picture entropy, which is why grainy tape is the number to plan on —
and why `uyvy` is the safe archival default when disk is cheap (a tape costs
35 GB, which is one HDD shelf-load).

`uyvy` is bit-exact *by construction*: `cmp` of 40 frames before and after the
muxer is identical. Audio is `pcm_s16le` there rather than `mp2`, for the same
reason — free and lossless. Both lossless modes are intra-only with **no rate
control**, so a busy scene makes the file bigger instead of making the encoder
miss a deadline; `dvd` is the only mode where a rate-controlled VBV can fall
behind, and the only one where a dropped frame costs the rest of a 15-frame GOP.

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

## 12. Where to look

| path | what |
| --- | --- |
| `pctv-linux/TRUTH.md` | **the authority** on hardware behaviour (§2.1 download order, §4 state machine, §6 analog path, §8 retracted claims) |
| `pctv-linux/probe.c` | the userspace driver: vendor request map, `analog2_bringup`, `stream` |
| `pctv-linux/pctv-monitor.c` | BT.656 parser, SDL2 view, capture masters (§10), AGC |
| `pctv-linux/live-module.nix`, `package.nix` | deployment: handoff unit, udev, sysctl, RT limits, firmware, wrappers |
| `pctv-linux/README.md` | usage, keys, options; and why `driver/` (the V4L2 module) is retired |
| `pctv-linux/COLD-BOOT-NOTES.md` | cold-boot runbook and symptom → cause → fix table |
| `docs/pctv-320cx.md` | the superseded Win7-VM route |

**The general lesson:** before writing a kernel driver for a USB device, capture what
the vendor driver actually puts on the wire. If the device is control-transfer + bulk
stream and only one program needs the data, userspace gets you a working product —
faster to iterate, no kernel-version coupling, no `CONFIG_RUST` toolchain, and nothing
to rebuild when the kernel bumps.
