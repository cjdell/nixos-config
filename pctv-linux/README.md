# pctv-linux — PCTV 320cx (dib0700) analog capture on Linux

Reverse-engineering notes and tooling for capturing **analog video** (composite
/ S-video) from a Pinnacle PCTV 320cx ExpressCard on Linux. The mainline
`dvb-usb-dib0700` driver is DVB-only and never enables the analog path, so the
hardware is driven directly over libusb — with one exception: that in-tree
driver still does the cold-start firmware download, because nothing else boots
the bridge ROM reliably from a true cold plug (TRUTH §2.1), and is then unbound.
Full journey: **`FINDINGS.md`**; ground truth: **`TRUTH.md`**.

> Want the short version — how analog capture works on a DVB-only bridge with a
> stock kernel and no kernel code at all? **`../docs/pctv-analog-capture.md`**.

## TL;DR — capturing a frame

```sh
./capture-live.sh composite1 6 menu best     # input, seconds, tag, field index
#   -> snapshots/menu-colour.png
#   -> snapshots/menu-grey.png
```

`input` is `composite1` or `svideo1`. `best` picks the most complete field;
you can also pass a field number, or `-1` (same as `best`).

Requires `sudo` (raw USB) and `/tmp/pyn` (a `nix shell --impure nixpkgs#python3`
wrapper, since python3 is not on PATH).

## How it works

Two non-obvious things had to be right, and both are in `capture-live.sh`:

1. **CX25843 setup through the demod's i2c gate**, with 2-byte register
   addressing. Notably `0x401 = 0xc0` switches the **colour killer off** —
   the vendor default leaves it on, which pins chroma to neutral and yields a
   grey picture.
2. **`ENABLE_VIDEO` mode 2** (`arm 0f 12 01 00`). The driver and kernel only
   use mode 1, which hands over just the active part of each BT.656 line and
   runs at 15.3 MB/s — under the 27.0 MB/s a PAL signal needs — so the bridge
   silently drops ~32 % of lines. Mode 2 passes the whole line (EAV +
   blanking + SAV + active) at 25.6 MB/s ≈ 95 % of lines. This was the root
   cause of every "missing chunks / warped geometry" symptom.

`decode-bt656.py` then parses the real BT.656 stream (EAV/SAV sync words give
field boundaries and blanking exactly) and writes a colour plus a greyscale
PNG from one complete field. No gap filling, nothing invented.

## Live monitor — userspace, no kernel module

`pctv-monitor` is a live monitor / capture GUI that talks to the card
**entirely through libusb**.  It does not use `/dev/video*` and does not need
the `pctv320cx` kernel module:

```
  pctv-monitor  (SDL2 GUI)
      └─ fork/exec ─ sudo -n pctv_probe stream <input>
                        └─ bring-up (proven analog2 sequence) → raw BT.656 on stdout
```

`pctv_probe stream <input>` is the "userspace driver": it reuses the exact
`analog2` bring-up, arms video mode 2 (off→on, the only ordering the bridge
accepts), then streams continuous BT.656 with 24 URBs in flight until
SIGINT/SIGTERM.  Diagnostics go to stderr, so stdout is a clean byte stream any
consumer can parse (the GUI, `mpv`, `ffmpeg`, a file).

### Through Nix (normal way)

The `hardware.pctv320cxLive` module installs both binaries and a `.desktop`
entry, boots the cold card with the **in-tree** `dvb_usb_dib0700` and then hands
the interface over to libusb (`pctv-bridge-handoff.service`, TRUTH §2.1), pins
the WirePlumber audio profile, and adds a udev rule:

```nix
# machines/macbook-pro-2009/default.nix
imports = [ ../../pctv-linux/live-module.nix ];
hardware.pctv320cxLive.enable = true;
```

```sh
just rebuild          # then: pctv-monitor   (or launch it from the app menu)
```

By default the GUI invokes the probe through `sudo -n`.  For a no-sudo launcher
set `hardware.pctv320cxLive.noSudo = true;` (installs `PCTV_NO_SUDO=1` into the
wrapper; relies on the module's `GROUP="video", MODE="0660"` udev rule and on
nothing holding the card — i.e. `pctv-bridge-handoff` having already unbound
`dvb_usb_dib0700`, and no other `pctv_probe` running).

Standalone (without the module):

```sh
nix-build -E 'with import <nixpkgs> {}; callPackage ./pctv-linux/package.nix {}'
# or: nix-build -E 'with import <nixpkgs> {}; callPackage ./pctv-linux/package.nix { noSudo = true; }'
```

### Manual build (for hacking on it)

```sh
./build.sh && ./build-monitor.sh
./pctv-monitor                      # as your desktop user; it sudo -n's the probe
```

Monitor keys: `1`/`2` switch video input (Composite, S-Video), `Tab` cycles,
`a` cycles the **audio input**, `A` toggles **automatic gain control**,
`-`/`+` capture gain, `b` input boost, `m` mute, **`o` monitors the input on the
speakers**, `c` **capture** (MPEG-2 by default, `--master` for the lossless
masters), `r`
raw BT.656 dump, `s` snapshot, `g` colour/grey, space pause the display,
`q`/ESC quit (Ctrl-C works too and still
finalises the `.mpg`).  The active input is named in an on-screen banner (and
in the window title, with the live field rate: ~50 fields/s = 25 interlaced fps
for PAL); the controls hint is shown for a few seconds after start and after
each input change.

The input can also be chosen at launch, which is what the `.desktop` entry and
scripts use:

```sh
pctv-monitor -i svideo          # or -i composite
pctv-monitor -l                 # list the video input names
pctv-monitor -L                 # list the audio input names
PCTV_INPUT=svideo pctv-monitor  # same, via the environment
```

### Audio input + level meter

The card's own analog audio path over USB is still undecoded (TRUTH §9.6), so
the pigtail's L/R RCAs go into a **host** input - on this box the 3.5 mm jack,
configured as line-in.  `pctv-monitor` captures that from ALSA and meters it
live, because "is the audio actually there, and is it in range" is otherwise
invisible on a picture.

* `-L` lists the inputs: they come from `/proc/asound/pcm` plus the codec's
  `Input Source` selector - the host-side equivalent of the vendor driver's
  "Audio Tuner In" / "Audio Line In" crossbar pins.  On the ALC889A here: the
  analogue ADC (`hw:0,0`) as `Internal Mic` / `Mic` / `Line`, the S/PDIF
  receiver (`hw:0,1`), and the alternate ADC (`hw:0,2`) with its own three.
* Default is the first **Line** input (the RCAs are line level); the choice is
  remembered in `~/.config/pctv-monitor/audio`, and `--audio <name>` /
  `PCTV_AUDIO=...` / `--alsa-dev hw:1,0` override it.
* The panel shows two stereo meters (-60..0 dBFS) with a shaded **-12..-3 dBFS
  target zone**, a moving RMS marker, a decaying peak-hold, the codec gain and
  boost in dB, a clip counter, and a verdict: `NO SIGNAL` / `LOW - raise gain
  (+)` / `OK - level in range` / `HOT` / `TOO HOT`.  With the AGC on, the
  verdict and its thresholds follow the AGC's target instead (`OK - AGC holding
  level`), so the panel never calls the level it is holding "LOW".
* Gain staging happens in the codec, not in software: `-`/`+` drive its
  `Capture` control (-16..+30 dB, 0.75 dB/step on the ALC889A), `b` cycles the
  per-input `* Boost` (0/12/18/24 dB), `--gain <0-100>` sets a percentage of
  the hardware range at startup.
* The stream goes through the sound server (see "Audio path" below), so it
  coexists with the desktop's own audio; if no route can be opened at all the
  panel shows the reason rather than pretending there is silence.

### Automatic gain control (`A`, on by default)

The source level on this wiring is not stable: measured on the same input, the
minimum codec gain (-16 dB) put the peaks at -40 dBFS and the maximum (+30 dB
capture, +30 dB boost) drove it to full scale, and the level has been seen to
move ~20 dB inside a single second by itself.  So the AGC drives the **codec**,
never a software multiply: the meter, the verdict and the recorded file always
describe the same signal.

* Target: peaks near **-18 dBFS** (`AGC_TARGET_DBFS`) from the **loudest
  peak of the last 30 s** (`AGC_WINDOW_S`), deliberately below the meter's
  -12..-3 manual zone.  A feedback loop has no lookahead on a live ADC, so the
  headroom is what keeps the source's step-ups out of the converter.
* Two rates.  **Calibration** moves at 0.5 dB/s (`AGC_RATE_DBPS`), which is
  what stops it pumping on a source whose level wanders.  **Emergency** is
  12 dB/s and only ever pulls *down*, latched for 500 ms after a post-gain peak
  within 1 dB of full scale (`AGC_HOT_DBFS`) or a measured clip.  Keying that on
  "near full scale" rather than on the clip counter is what matters: the gain
  staging can be 40 dB hot with the counter at zero for seconds at a time,
  because it only counts samples that land on the rail.
* Two guards.  A reference peak **below -50 dBFS** (`AGC_SIGNAL_MIN_DBFS`) is the
  noise floor, not programme, and the loop holds still for it instead of
  calibrating to it; an error beyond 24 dB against a reference is treated as an
  unbelievable measurement and the loop holds (except in the emergency, where
  the measurement *is* the full-scale peak and cannot be wrong).
* Total gain is capped at **+36 dB** (`AGC_MAX_TOTAL_DB`).  Past that it is only
  amplifying its own noise floor, and a line-level deck never needs it.
* **Why the two guards exist** (2026-11-02).  A capture started while the deck
  was still paused: staging measured tape hiss at -64 dBFS, and a loop that
  believed it walked the gain to its +49 dB maximum.  The programme then arrived
  30-40 dB hot - 4575 clipped samples in the first second, and the 0.5 dB/s
  calibration needed the whole minute to walk it back down, so the file ramps
  37 dB from start to finish.  The old "do not hunt a dead input" limit was
  -75 dBFS, *below* tape hiss, so it never fired.  Now the hiss guard holds the
  gain and the emergency clears an over-hot start in about a second.  Measured
  A/B on a noise-only input, both binaries started at +49 dB: the old one climbed
  to **+56 dB**, the new one holds at the +36 dB cap.  On the next real 60 s take:
  **0 clipped samples** out of 5.76 M and a flat level.
* Two gain stages.  The fine `Capture` control is used first; when it runs out
  of headroom the AGC takes a `* Boost` step and re-centres the fine control,
  and when the fine control has drifted below 20 % of its range it trades a
  boost step back for headroom, because the boost stage is the noisier one.
* Measured on the live source (20 s, source swinging on its own): peaks held in
  -5..-18 dBFS with **12 clipped samples** in the file.
* `A` toggles it; `-`, `+` or `b` turn it off (the user's hand wins).  `--agc`
  / `--no-agc` set it from the command line.  Input, gain, boost **and** the
  AGC flag are all remembered in `~/.config/pctv-monitor/audio` (line 1 =
  input, line 2 = `<gain%> <boost step> <agc>`), so the next launch comes back
  where you left it - including AGC off, if that is where you left it.

### Audio path: the sound server, not raw hardware

Capture and monitoring both go through the **desktop sound server** (ALSA
`default`, which on this system is PipeWire's plugin), with raw `hw:x,y` as an
automatic fallback.  That is what makes it reliable: an exclusive raw capture
fought the daemon in both directions - `EBUSY` when PipeWire had a profile with
an input, silence when it had none - and the panel could not tell you which.
The panel and the log now name the route (`AUDIO: Line via default`), and every
candidate is tried completely (open **and** hw params), because the plugin opens
happily even with no input available and only fails at `set_params`.

The card profile that makes this work is **pinned in NixOS** by this module
(`hardware.pctv320cxLive.audioProfile`, default
`output:analog-stereo+input:analog-stereo`): a profile with both a sink and a
source.  WirePlumber 0.5 would otherwise restore whatever the desktop menu last
chose - this box had stored `off`, which produced a Dummy Output, no source and
no desktop sound, and outranked every preference rule (seen in a debug run as
`Found stored profile 'off'`).  So the module also sets
`device.restore-profile = false`: on this host the audio profile is declared,
not chosen at runtime.  Set `audioProfile = ""` to leave WirePlumber alone.

The **codec controls** are still driven directly through the card's control
device (`controlC0`): it is multi-client, and `Input Source` and the `* Boost`
elements are not exposed by the sound server at all - the AGC needs them.

Override the route for experiments with `PCTV_ALSA_DEV=hw:1,0` (or
`--alsa-dev`).

### Input monitoring (`o`) - hear the gain before you record

`o` plays back, on the host's output, **exactly the samples the capture would
write** - the same buffer, unaltered, after the codec's gain and boost.  So the
meter and your ears judge the same signal, before committing to a recording.

* Toggled with `o` (or `--monitor` at launch).  The output stream is opened only
  while monitoring is on and closed again, so the desktop's audio is not held
  the rest of the time.
* It goes through the sound server (`default`) and falls back to the card's own
  playback stream.  With the profile pinned by the module, `default` is always a
  real sink, so monitoring follows whatever the desktop is routed to - speakers,
  headphones, Bluetooth.  (It used to be hw-first precisely because an unpinned
  profile made `default` a Dummy Output; that is now fixed declaratively.)
* If the codec's `Master` is muted or near silent (PipeWire leaves it wherever
  the desktop put it), monitoring raises it to a moderate level and says so, so
  a silent output is never mistaken for a dead input.
* Latency is roughly 60-100 ms (capture period + a 60 ms playback buffer).  That
  is fine for judging level, too slow to play along with.
* If the selected input is a **Mic** or **Internal Mic**, the panel says
  `feedback risk` - speakers into a mic will howl; use line in or headphones.

### Capture (`c`) — MPEG-2 by default, lossless with `--master`

The deframed UYVY is piped to `ffmpeg` on stdin and the ALSA PCM on fd 3; the
default result is a plain PAL-DVD-style program stream - `mpeg2video` 720×576
interlaced at 25 fps (`-b:v`/`-maxrate` 6000k, `-bufsize` 1835008, `-g 15`,
`+ilme+ildct`, 4:3) plus `mp2` 48 kHz stereo 192k.  The *pixels* are
top-field-first; that stream is not tagged as such, and cannot be - see
"Which master to write" below and `docs/pctv-analog-capture.md` §10.3.

#### Which master to write (`--master`, `PCTV_MASTER`)

`dvd` (the above) is for burning and watching.  For an archive, `--master
utvideo`, `--master ffv1` or `--master uyvy` writes a **lossless Matroska
master** instead:

| mode | what it is | size on real tape | encoder speed | field order in the file | quality vs the lossless source |
| --- | --- | --- | --- | --- | --- |
| `dvd` | MPEG-PS `mpeg2video` 6 Mbps, `-g 15` | 0.72 MB/s | 5.1× realtime | bitstream, TFF | SSIM 0.970 / PSNR 43.8 dB |
| `dvd --bitrate 15000` | the same at 15 Mbps (the encoder is quantiser-limited: 25 Mbps gives the same file) | 1.33 MB/s | 4.7× | bitstream, TFF | SSIM 0.985 / PSNR 47.0 dB |
| **`ffv1`** | Matroska `ffv1 -g 1` (yuv422p) | 4.0 MB/s (240 MB/min) | 4.5× | **frames say TFF** | **lossless** |
| `utvideo` | Matroska `utvideo` (yuv422p), all-intra | 5.1 MB/s (300 MB/min) | **14×** | **nothing** — needs `pctv-field-order --relabel` | lossless |
| `uyvy` | `rawvideo`, the deframer's own bytes, no conversion at all | 20.7 MB/s (1.2 GB/min) | 8.0× | frames say TFF | lossless — but see below |

**`ffv1` is the archival master.**  It is lossless (verified bit-identical to the
source through `framemd5`), it costs 4.5× realtime so it keeps up live (measured:
0 skips), and — the part that decides it — it is the only *fast* lossless codec
here that **writes the field order into the file**.  `utvideo` is three times
faster and the same size, but it writes neither a bitstream flag nor a container
element, so a plain player treats the frames as progressive: it either combs or
falls back to 25p, which is exactly the smoothness an archive exists to keep.
Use `utvideo` when you want the lowest CPU, and then run
`pctv-field-order --relabel FILE` (a stream copy, seconds) on it; the capture
says so at stop.  **`uyvy` was the awkward one and no longer is**: it used to drop
frames ("17 in 60 s") because the capture queue was 6 pictures deep and evicted the
oldest when the sink fell behind.  Since the no-eviction change (docs §14.2b) a
10-minute `uyvy` master measured `qmax 1/150`, `dup 0 skip 0 refused 0` and 0 drops,
and a 3 s freeze of the encoder mid-capture is now absorbed with nothing lost.  It is
the archival mode with the *least* that can go wrong, because there is no encoder in
the path at all - the cost is purely bytes (see "Recording a raw master" below).

#### Recording a raw master - the desktop entry, the audio, and where it goes

The menu has **two** entries, and the difference is the whole question:

| entry | what it runs | format | destination |
| --- | --- | --- | --- |
| PCTV 320cx Live | `pctv-monitor` | MPEG-2 DVD (`--master dvd`) | `~/Videos` |
| **PCTV Capture (raw master to NAS)** | `pctv-capture-nas` | **lossless UYVY + PCM** | **`/ds-public/pctv-masters`** (GEN8, NFS) |

The second one is just the same program with two variables set, so it is also
available by hand, and they are the only two you need:

```sh
pctv-capture-nas                                   # the desktop entry, from a terminal
PCTV_MASTER=uyvy PCTV_OUT_DIR=/ds-public/pctv-masters pctv-monitor   # equivalent
```

* **Yes, it records audio.** Every master carries sound: `pcm_s16le` 48 kHz stereo
  inside the `.mkv` (`mp2` inside a `dvd` `.mpg`), taken from the input `a` cycles -
  normally **Line (hw:0,0)**, which is the pigtail's RCAs, and the choice is *saved*
  in `~/.config/pctv-monitor/audio`. `--no-audio` turns it off **and remembers that**,
  so check the line the summary prints: `audio Line (hw:0,0) via default (48000 Hz)`
  means you are recording sound, `audio none` means you are not. `pctv-monitor -L`
  lists the inputs.
* **The NAS is the destination only via that entry** - nothing about the machine's
  defaults changed, so the plain entry still writes MPEG-2 to `~/Videos`. That is
  deliberate: a raw master is **20.9 MB/s = 1.25 GB/min = 12.6 GB per 10 min = 151 GB
  per 2 h tape**, which is not a laptop-SSD number (118 GB free) and is a rounding
  error on GEN8's 17 TB pool. `pctv-capture-nas` therefore **refuses to start** unless
  `/ds-public` is genuinely an NFS mount (`findmnt -T … -t nfs4`): a capture pointed at
  a directory that is only the mount point, locally, would write 12 GB to the SSD and
  look exactly like success. The monitor itself exits 3 if `PCTV_OUT_DIR` is not
  writable, for the same reason.
* **It is not the write path that limits anything**: `ds-public` measured 123 MB/s
  sustained buffered writes (5-6× what a master needs), and the encoder was never in
  the picture for `uyvy`.  What the queue is sized against is ffmpeg's 10 s stream
  interleaving limit, not the disk (docs §14.2b).

Prove a run in ten seconds rather than hoping:

```sh
f=/ds-public/pctv-masters/pctv-cap-….mkv
ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 $f
ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 $f \
  | awk 'NR==1{p=$1;next}{d=$1-p; if(d<0)d=-d; if(d>0.0401)b++}END{print "steps off 40 ms:", b+0}'
ffmpeg -nostdin -v error -i $f -map 0:a -c copy -f null - && ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 $f
```

The monitor's own line says the same thing at stop: `15001 frames [dup 0, skip 0,
refused 0, qmax 1/150 …], 115416392 B audio (0 B cut …), 0 video drops`.  A *short*
file that is complete beats a long one with holes in it - that is the whole policy
(`pctv-linux/queue-selftest.sh` is the test that keeps it true).

**Then transcode it when you have time** - the master is the tape, not the deliverable.
Verified on this box (30 s of tape → 22.9 MB, `field_order=tt`, every frame
`top_field_first=1`, mp2 audio):

```sh
ffmpeg -field_order tt -i master.mkv \
  -c:v mpeg2video -b:v 6M -maxrate 6M -bufsize 1835008 -g 15 -flags +ilme+ildct \
  -aspect 4:3 -c:a mp2 -b:a 192k -f mpeg master.mpg
```

`-field_order tt` **must precede `-i`**: `mpeg2video` records the order the *demuxer*
reported and a raw demuxer reports nothing unless told (docs §10.3).  This laptop
encodes MPEG-2 at ~5× realtime, so 2 h of tape is ~25 min here - or run it on
`zen3-nixos`, which mounts the same `/ds-public` and has 32 cores, while the laptop is
back on the VCR.

`libx264 -qp 0` is also lossless and writes the flags, but it runs at **0.71×**
realtime here (`-crf 12` at 0.48×), so x264 is not an option at any quality
setting on this box.  MPEG-2 has no headroom left to buy either: `-b:v 15000k`
and `-b:v 25000k` produce the *same* file, because the encoder runs out of
quantiser before it runs out of bitrate.

`pctv-field-order FILE...` prints what a capture claims about field order in
three readings - container element, decoded-frame flags, `idet`'s pixel vote -
and what to do when they disagree; `--relabel` stream-copies a container-tagged
Matroska twin (which fixes the label, never the MPEG-2 bitstream).

* Files land in `~/Videos/pctv-cap-<timestamp>.mpg` (`.mkv` for the lossless
  masters); `--out-dir` / `PCTV_OUT_DIR` chooses the directory (else `/tmp`),
  `--bitrate <kbps>` / `PCTV_MPEG2_BITRATE` the DVD bitrate, and
  `--master dvd|uyvy|ffv1` / `PCTV_MASTER` the format.
* The encoder starts on the **first decoded frame**, not on the key press, so
  both streams share PTS 0 - otherwise a capture started while the decoder is
  still hunting carries up to 8 s of extra audio (the lock poll, see below).
* **Recording is obvious on screen**: a 4 px red border around the frame, a
  large `REC mm:ss.t` badge with a dot blinking once a second, and a line with
  frames, bytes, the drop counters and the encoder queue occupancy.
* Frames are queued **where they are born** (24 slots, one per assembled
  picture, 960 ms) and a single **writer thread** owns every write to ffmpeg's
  two pipes.  Writing an 829 KB UYVY frame inline meant the display waited on the
  encoder - and while the main loop waits, nothing drains the probe either, so the
  whole pipeline hiccups.
* **The picture is the clock.**  A queued frame goes to ffmpeg the moment it
  exists, so the file's cadence *is* the card's field cadence and no difference
  between the two crystals can ever evict a picture.  The wall clock is only a
  watchdog: if the source stops producing frames for longer than a frame period
  (+30 ms) the last picture is repeated, so a paused deck or an input switch
  cannot shorten the video track.  The overlay calls this `card clock`.
* **One commit, one pair: the audio is written as part of the picture's
  commit.**  Since 2026-11-04 the writer's unit of work is one 829440 B picture
  followed by exactly 40 ms of sound (1920 frames at 48 kHz), to the two pipes in
  that order and by no other path in the program.  Sound leaves the audio ring
  *only* inside a commit, so the muxer can never see one track advance without
  the other and A/V sync is a property of the write, not something a log line
  reports afterwards.  `PCTV_CLOCK` (the audio-paced legacy writer of
  2026-11-01) was retired the same day; setting it now only prints a warning.
  Full reasoning and the measurements: `docs/pctv-analog-capture.md` §11, §14.2f.
* **The audio is resampled onto that timeline.**  The card's 25 fps comes from
  the incoming video signal and the PCM from the host codec's own crystal; on
  this box they differ by ~135 ppm = 1 s per two hours.  Rather than let that
  cost pictures, `rs_update()` measures the crystals' ratio over the ADC's
  *arrivals* (reading the drain back would be an instrument wired to its own
  output) and spends it - plus the live phase error `E` = picture-queue depth
  - audio-ring depth - linearly resampling the sound at the commit (the
  overlay shows both: `+135 ppm  ph +0 ms`; on a tape 0.23 cents of pitch is
  nothing).  Both tracks are then the same length by construction, exactly, and
  the stop line repeats the figures.
* Nothing is dropped to keep up any more: the audio ring is 4 MiB of raw ADC
  frames (21.8 s - the depth only ever matters against the 6 s picture queue it
  shadows), the video ring 960 ms and the encoder's own video pipe 8 MiB
  (10 frames), and both pipes are non-blocking with a resume-on-partial write,
  so a stalled encoder costs latency and, at the very worst, counted drops -
  never a wedged GUI, a corrupted stream or a hung `c`.
* **`dup` and `skip` are the two numbers that say whether the recording kept every
  picture.** `dup` = the source delivered no new picture in time (one frame
  written twice - a visible drag); `skip` = the queue filled and the oldest frame
  was evicted (a picture lost - a visible jump).  A clean capture reads
  `dup 0, skip 0`; the stop line repeats them.  With the card as the clock these
  can only come from the *source* stopping or the encoder falling behind -
  never from the two clocks, which is what the ppm figure is for.
* **A hole in the USB stream no longer costs a picture either.**  A guard code at
  the wrong pitch proves exactly how many BT.656 lines vanished, so the parser
  advances the row counter by that many and fills the gap from the previous
  clean frame's same-parity rows (`gap_resync`).  Before 2026-11-02 it threw the
  field away, which is 25 repeated pictures a second on a marginal USB path.
  The final line prints `stream gaps of N B/M rows repaired`.
* Watch a `.mpg` with the field order declared (`ffplay -top 1`, `AssumeTFF()`):
  MPEG-2 cannot carry it, and a player that guesses wrong deinterlaces every
  moving object backwards - which is what "the recording is not as fluid as the
  live view" usually was, on top of the cadence work above.  `--master ffv1` and
  `uyvy` stamp the flag correctly.
* **Play an interlaced capture *as* interlaced**, or it cannot look as smooth as
  the live view.  The card's 50 fields/s are two 25 Hz half-pictures; a player
  that shows 25 whole frames a second (or blends them) throws half of the motion
  away no matter how perfect the file is.  Bob the fields back to 50 Hz:

  ```sh
  mpv --deinterlace=yes '--vf=bwdif=parity=tff' FILE      # 50p, full height per field
  ffplay -vf bwdif=mode=send_field:parity=tff FILE        # same, no mpv
  ```

  `bwdif`'s `send_field` is the default and is the point: 50 distinct time
  samples per second, which is what the eye compares against the live picture.
  For an archive, keep the master interlaced and produce 50p with QTGMC on the
  fast machine (`footage/README.md`); on this box `bwdif` is the most that fits.

Knobs for the capture path (all environment, all optional):

| variable | default | what it does |
| --- | --- | --- |
| `PCTV_VQ_SLOTS` | 150 (`dvd`: 24) | video queue depth in frames, ceiling 500 (each costs 829 KB); the lossless masters run the 150-slot = 6 s sink cushion, the MPEG-2 path keeps 24. Past the queue the spill below takes over, so raising this only trades RAM |
| `PCTV_SPILL_MB` | 32768 | how much **local** disk (MiB) the queue may overflow onto: when the RAM queue fills, pictures *plus their own 40 ms of sound* append to a scratch file and the capture runs on — the §14.2b `SINK STALLED` stop now only fires when even the scratch file says no (cap, full or failing disk). The effective figure is further clamped to the measured free space minus a 1 GiB floor. `0` disables the spill: a full queue ends the capture, the pre-2026-11-04 behaviour (§14.2g of the doc) |
| `PCTV_SPILL_DIR` | `/var/tmp` | where that scratch file lives: it **must be local disk** — spilling onto the same slow mount is circular. The file is created with `mkstemp` and unlinked at once, so a crash leaves nothing behind; the space returns when the take ends |
| `PCTV_HOLD_SECS` | 600 | end-of-tape: how long a **bit-identical** picture may run inside a file before the file is closed; the card stays claimed and a new file opens when the picture moves again. `0` never closes (a frozen frame is then recorded for as long as it lasts). 600 rather than 120 because a **damaged** stretch of tape reads as a frozen picture (the frame gate holds the last clean frame) and is not the end of anything — at 120 the file was cut in the middle of one |
| `PCTV_HOLD_MAX` | 0 (watch for ever) | also end the *run* this many seconds after the picture stopped, releasing the card - the one to set for an unattended overnight tape (`900` = quit 15 min after it ends); clamped up to `PCTV_HOLD_SECS` |
| `PCTV_BLUE_SECS` | 60 | no content: the deck's **blue screen** is *not* a frozen frame (the no-signal subcarrier beats, so every frame differs) but it is unmistakably blue and dark — mean Y≈48/U≈206/V≈116 against Y 94-113/U≈123 for programme. After this many seconds of it the run ends and the card is released, because that blue is the deck saying there is nothing to play. Only counts once a real picture has been seen in the file, so a monitor started in front of a stopped deck does not quit; `0` never ends |
| `PCTV_HOLD_RESUME` | 25 | changed frames (1 s) needed before the picture counts as back, so one tracking glitch cannot open a file |
| `PCTV_HOLD_STRESS` | - | self-test: report a frozen picture for the first N seconds whatever the deck is doing, so both transitions (close, reopen) can be exercised without waiting for a tape to end |
| `PCTV_STREAM_BUF` | 64 | the probe's stdout ring in MiB (2.4 s per 64); `0` = old drop-on-EAGAIN |
| `PCTV_URBS` | 128 | how many 32 KiB URBs stay posted on the endpoint: the card's *own* FIFO cushion, 8..512 (128 = 4 MiB = 155 ms). 24 (~28 ms) was the old value and cost a field every few seconds on a busy box |
| `PCTV_TUNE` | 1 | `0` skips the probe's stream-time tuning (cpu_dma_latency, cpufreq `performance`, usbfs_memory_mb) for an A/B run |
| `PCTV_CLOCK` | - | **retired 2026-11-04**: both capture-clock modes were replaced by the coupled commit (one picture + its 40 ms of sound, written together - see §14.2f of the doc); setting it only logs a warning now |
| `PCTV_FFMPEG_DEBUG` | - | print the whole ffmpeg command line at capture start |
| `PCTV_LOG` | **always on** | every line - monitor, probe and ffmpeg alike - goes to `$XDG_STATE_HOME/pctv-monitor.log` AND to the terminal, each stamped `[YYYY-MM-DDTHH:MM:SS.µs]` by a tee thread that can never block a capture thread (a full log pipe drops lines, never stalls the take); a `log start:` line pairs wall-clock with the monotonic clock so an NTP step mid-take is visible. `PCTV_LOG=/path` moves the file, `PCTV_LOG=0` drops it and leaves stderr undecorated |
| `PCTV_MASTER` | `dvd` | `dvd` / `uyvy` / `ffv1` (`--master` on the command line) |
| `PCTV_RT_PRIO` | monitor 8, probe 10 | `0` turns RT off for an A/B run.  Inside the monitor the capture writer and the ALSA reader always sit one level above the parser/renderer (9 vs 8), and never below whatever this sets |
| `PCTV_VERBOSE` | - | one status line per second, including `q <depth> dup N skip N` |
* `ffprobe` reports `field_order=bb` for these files even though the sequence
  extension carries `top_field_first=1` (read the byte after `00 00 01 B5`);
  that is a probe quirk - do not "fix" the encoder flags.  `-top 1` is not even
  accepted as an encoding option in ffmpeg 9.

The card has one composite input (the yellow RCA) and one S-Video connector;
the other two RCAs are L/R audio.  Composite and S-Video share the same
CX25843 luma pin, so a source plugged into one connector still shows (luma
only) when the other input is selected; the CX25843 bring-up clears CKILLEN so
chroma is decoded on the selected input.

Headless checks (no display needed):

```sh
SDL_VIDEODRIVER=dummy PCTV_VERBOSE=1 ./pctv-monitor          # prints fps to stderr
PCTV_SNAP_AFTER=120 SDL_VIDEODRIVER=dummy ./pctv-monitor     # saves one frame, exits
# 6 s MPEG-2 capture, then exit (the audio meter still updates in the log):
SDL_VIDEODRIVER=dummy PCTV_VERBOSE=1 ./pctv-monitor --audio line --capture --capture-seconds 6
# watch the AGC work (one log line per gain move, including boost staging):
SDL_VIDEODRIVER=dummy PCTV_VERBOSE=1 ./pctv-monitor --agc --gain 0 --capture --capture-seconds 10
# check the monitor path reaches the hardware (both streams must show RUNNING,
# owned by the same pid, in /proc/asound/card0/pcm0{p,c}/sub0/status):
SDL_VIDEODRIVER=dummy ./pctv-monitor -i svideo --monitor --capture-seconds 10
# or drive the stream directly:
sudo ./pctv_probe stream composite1 > /tmp/live.bin          # raw mode-2 BT.656
```

### Proving the capture path keeps every field, without the card

```sh
./capture-selftest.sh        # -v for the anomaly timeline
```

`fakeprobe.c` emits real-time BT.656 in exactly this card's line layout and can
inject the two things that go wrong - a lost 32 KiB URB (a hole at a mid-line
byte offset) and a hole aligned to whole lines (which no parser can locate) - and
the script also `SIGSTOP`s the driver for a second to emulate the desktop being
away.  Each case is asserted against the counters on the stop line (`dup`,
`skip`, `short`, `repaired at the seam`, `held`), so a change that starts costing
a picture fails the script instead of a tape.  Expected output: a list of PASSes,
the four captures' summaries, and `all checks passed`.

`PCTV_VERBOSE=1` prints one line per second: the codec's gain, the meter peaks,
the clip count, the byte counters, the encoder queue occupancy, and the **worst
main-loop gap of that second broken down into `parse` / `feed` / `render`**.
That breakdown is the instrument for "the picture froze": a large `render` gap
is the display path, a large `parse` gap is the incoming stream, and a `feed`
gap or a full queue means the encoder is not keeping up.  `PCTV_HELP=1` starts
with the help overlay up (it is normally toggled with `H`).

Independent of `PCTV_VERBOSE`, one `HB` line lands in the log every second -
the take as a diffable record, with `f`/`a`/`dup`/... as **deltas over the last
second** and `q`/`sp`/`e` as instantaneous values:

```
monitor: HB t=899068.776592 f=25 fld=50.0 a=48000 q=1 sp=0 e=+0 dup=0 skip=0 ref=0 spill=0 pad=0 sil=0 xrun=0 adrop=0
```

`t` is the monotonic clock in seconds (it pairs with the `log start:` anchor
line; every log line's stamp is the same moment on the wall clock), `fld` the
fields/s the ADC delivered, `f` the pictures the muxer committed - a `fld` of
50 with an `f` below 25 is the pipeline falling behind, live. `q`/`sp` say
where the backlog lives (RAM queue / spilled to disk, §14.2g), `e` is the
A/V phase the resampler is steering. The rest are the loss counters of the
stop line, one second at a time: an unbroken line of zeros is a healthy take,
and **the second the zeros stop is the second to go look at**. Frame numbers
map straight into the master - 829440 B of video and 1920 B of audio per
40 ms frame - so `f`-sums are byte offsets: this is the index a repair pass
(starting where §14.2e leaves off) reads instead of re-watching tape.

With **no source playing** the decoder's lock poll (`poll for a real lock`,
16 × 500 ms in `analog2_bringup`) delays the first data by ~8 s; the monitor
just shows no picture until then, and captures queued with `--capture` start at
the first frame.  Settle time after a cold plug is another ~10 s (TRUTH §1).

### End of tape: the file closes, the card stays, a new file opens on its own

A deck that reaches the end of its tape does not stop the digitiser - it hands the
card the same field for ever.  That is detectable exactly rather than by thresholds,
because "for ever" means **bit-identical**: nine hours of end-of-tape hold folded to
one 64-bit hash of the frame (and to Y=16 U=128 V=128, video black), while every one
of the 960279 frames of programme before them differed.  Live tape that merely looks
still - a held shot, a title card - differs too, because tape noise is in it.  The
monitor folds each frame it would encode into 64 bits (82 us, 0.2 % of this box, four
accumulators because the fold is a dependency chain and not a bandwidth problem) and
acts on the run length.

What it does when the picture stops moving is **not** stop: after `PCTV_HOLD_SECS`
(default 600) it closes the file - cleanly, the same path `c` and Ctrl-C take, so the
MPEG is finalised - keeps the card claimed, and opens a fresh file once `PCTV_HOLD_RESUME`
frames (1 s) have changed.  Nothing has to be right about *why* the picture stopped.
A blank stretch between two recordings on one tape therefore costs a file boundary
and ten minutes of tail (45 kB/s while frozen, against 699 kB/s of programme), where
a guess that said "end of tape" used to cost the rest of the tape.  The overlay says
`STILL mm:ss - file closed, waiting`, the window title gains `[STILL]`, and `c` at any
time takes back control (it re-arms the window and cancels the automatic reopen).

Ten minutes and not two because a **damaged** patch of tape looks exactly the same
from here: the frame gate replaces every unclean frame with the last clean one, so the
frames handed to the encoder are bit-identical and a 2 min window cut the file in the
middle of the damage (2026-11-03) and then stopped recording the rest of it, waiting
for a picture that was never coming back on its own.

For an unattended tape, `PCTV_HOLD_MAX 900` also ends the run 15 min after the picture
stopped, which releases the card.  Left at 0 the monitor simply keeps watching, which
costs nothing on disk because the file is already closed.

### No content at all: the blue screen *does* end the run

A deck with nothing to play shows a blue screen, and unlike the frozen frame above it
is not bit-identical - the no-signal colour subcarrier beats against the digitiser's
sampling clock, so 749 consecutive frames of it in the 2026-11-02 capture had zero
identical pairs (docs/pctv-analog-capture.md §12).  It is, however, unmistakably
*blue*, and that is measured rather than thresholded: mean plane values in 8-bit
codes are **Y 47.9 / U 206.2 / V 116.4** for the deck's blue (real s-video, checked
live 2026-11-03) against **Y 94-113 / U 123-129 / V 129-150** for programme, with
neutral chroma at 128.  U alone separates them by ~77 codes.

So after `PCTV_BLUE_SECS` (default 60) of a frame whose mean is blue-and-dark (U >= 170,
Y <= 110) **and whose means are not moving** (within 3 codes of the first frame of the
run, so a real blue thing in a shot cannot accumulate the window), the monitor closes
the file **and ends the run**, releasing the card - the tape is over.  The overlay says
`NO SIGNAL mm:ss - blue, ends the run at mm:ss` and the title gains `[NO SIGNAL]`.
Only while capturing, and only after a real picture has been seen since the file
opened, so a monitor started in front of a stopped deck waits for the tape instead of
quitting.  `PCTV_BLUE_SECS=0` turns it off; `PCTV_VERBOSE` prints the three means
every second (`monitor: blue: Y … U … V …`) so the predicate can be checked against a
deck.

What this cannot see is a deck that answers end of tape with *static*: snow changes
every frame, so it is programme-shaped to every detector here and in
`scripts/pctv-autoend.sh`.  `--capture-seconds` is the honest answer for that deck.

`PCTV_HOLD_STRESS=<s>` reports a frozen picture for the first `s` of a run whatever
the deck is doing, so both transitions can be tested without waiting for a tape to
end - one run proves the first file is finalised and the second opens and records
(verified 2026-11-02: 151 frames in 6.05 s, then 425 in 17.02 s, both `field_order=tt`,
`dup 0 skip 0`, zero drops either side).

Notes / current limits:

* Luma is correct and the picture is stable at the full 50 fields/s.  Chroma
  is now decoded (the bring-up clears the CX25843's CKILLEN, `0x401` bit 6,
  which the vendor default leaves on and which pins the picture to grey);
  residual rainbow fringing at chroma edges is the §14 resampling work, not
  yet applied here.
* **The card's own audio-over-USB is still undecoded** (TRUTH §9.6): the
  analog audio is digitised on-card, but the only stream endpoint that ever
  delivers is `0x82`, and it carries raw BT.656 video; the vendor Windows BDA
  driver's audio framing is not decoded.  `pctv-monitor` therefore captures the
  **host's** ALSA input (line-in) for the pigtail's L/R RCAs, with the selectable
  input and live meter described above - which is also what the MPEG-2 capture
  muxes.
* PAL only for now; the parser keys off the BT.656 F/V bits but the output
  geometry is hard-wired to 720×576.
* The child needs raw USB.  By default it is launched via `sudo -n`;
  `hardware.pctv320cxLive.noSudo = true;` (the udev rule it installs) removes
  that requirement.

## The driver — `driver/` (retired: not built, not enabled)

The same reverse-engineered bring-up also exists as a kernel module:
**`pctv320cx.ko`**, Rust core + C V4L2 glue, in `driver/`.  **Nothing builds or
loads it any more** — no `.nix` in the repo imports `nixos-module.nix`, and
`machines/macbook-pro-2009/default.nix` enables only
`hardware.pctv320cxLive` (the userspace path above).  It stays here because it
was the route that first proved the analog bring-up end-to-end inside the
kernel, and because `COLD-BOOT-NOTES.md` §5.5 documents how to go back to it.
Everything below describes how to rebuild it, not what this host runs.

| file | role |
| --- | --- |
| `pctv320cx.rs` | driver core (Rust): DiB0700 firmware download, I2C tunnel, CX25843 programming, bulk-IN capture, BT.656 → UYVY (Cb Y Cr Y) deframer |
| `v4l2-glue.c` | the V4L2 face: `video_device`, `vb2_queue`, ioctl table, control handler, buffer handoff |
| `usb-shim.c` | `struct usb_driver` registration, endpoint helpers, firmware request, `MODULE_DEVICE_TABLE` |
| `pctv320cx.h` | the seam between the two halves (`struct pctv_ops`, `pctv_glue_*`) — also the bindgen input |
| `Kbuild` | kbuild rules: C objects, the Rust object, and the **bindgen-generated bindings** |
| `bindgen_parameters` | the kernel's own bindgen tweaks (opaque/blocklisted types) |
| `Makefile`, `package.nix` | out-of-tree build (`make KDIR=…`) and the Nix derivation |

Build (kernel must have `CONFIG_RUST=y`; the bindings are generated from that
kernel's headers at build time, exactly like the in-tree `bindings` crate):

```sh
# against the running kernel
make
# against a prepared build tree
make KDIR=/lib/modules/<version>/build
# Nix: against the MacBook's kernelPackages
nix build --impure --expr 'let f = builtins.getFlake "/home/cjdell/nixos-config";
  kp = f.nixosConfigurations.macbook-pro-2009-nixos.config.boot.kernelPackages;
  in import ./pctv-linux/driver/package.nix { stdenv = kp.stdenv; kernel = kp.kernel;
                                             lib = import <nixpkgs/lib>; }'
```

Re-enable on the MacBook (the host with the ExpressCard slot) by importing
`nixos-module.nix` and setting `hardware.pctv320cx.enable = true;` — it adds the
module to `boot.extraModulePackages` / `boot.kernelModules`, pulls in
linux-firmware (`dvb-usb-dib0700-1.20.fw`, `v4l-cx25840.fw`) and **blacklists
`dvb_usb` / `dvb_usb_dib0700`** so the module can claim the card.

> ⚠️ **Do not enable it next to `hardware.pctv320cxLive`.** That blacklist is
> precisely what the userspace path must *not* have: TRUTH §2.1 says the in-tree
> driver has to be the first downloader after a cold plug, which is why
> `live-module.nix` loads `dvb_usb_dib0700` on purpose and unbinds it again once
> `/dev/dvb/adapter0` appears.  Both options grab the same USB interface, and
> the combination leaves the card neither booted nor streamable.

Module metadata after a successful build:

```
alias:   usb:v2304p022Ed*…      depends: videodev,videobuf2-v4l2,videobuf2-common,videobuf2-vmalloc
firmware: dvb-usb-dib0700-1.20.fw, v4l-cx25840.fw      parm: debug (u32)
```

**Status: built, ran on hardware, then superseded by the userspace path.** It
built clean against the MacBook's kernel and worked: it bound the card, exposed
`/dev/videoN` ("Pinnacle PCTV 320cx"), and captured stable 25-fps frames from
both S-Video and Composite 1 (TRUTH §1, 2026-10-08 ~19:03).  It was dropped 20
minutes later (`f70a608`, 19:22), not for failing but because the userspace
stack covers live view *and* MPEG-2 + audio capture in one program, while the
V4L2 face still showed the unfixed chroma — the colour killer *is* cleared there
(`0x401 = 0xc0`), but the §14 chroma/resampling work never was, so composite
came out near-greyscale and S-Video rainbow-fringed (TRUTH §1).  The one thing
the kernel still has to do — boot the bridge ROM from a true cold plug — is done
better by the in-tree `dvb_usb_dib0700`, which `live-module.nix` loads for
exactly that and then unbinds.

## State

* **Geometry: solved.** Full 288-line fields, sharp, correctly proportioned.
* **Colour: inconclusive, probably mostly absent on the test disc.**  On the
  DVD menu used as a reference the chroma has no stable component (it averages
  to grey faster than noise would) and rises monotonically with the luma
  gradient — i.e. it is luma-edge leakage, not real chroma. See `FINDINGS.md`
  §12. Earlier captures of other content *did* show genuine flat colour, so
  the decode path can carry colour; whether this disc has any is unresolved.
* Sharper S-video made **no difference**, which argues against cross-colour
  being the mechanism (see §12.1).

## Layout

| path | what |
| --- | --- |
| `FINDINGS.md` | the whole investigation — read this first |
| `driver/` | the retired kernel module (Rust core + C V4L2 glue), see above |
| `nixos-module.nix` | `hardware.pctv320cx.enable` — deploy that module (imported by nothing; conflicts with `live-module.nix`) |
| `live-module.nix` | `hardware.pctv320cxLive.enable` — **what the host actually runs**: userspace stack + cold-boot handoff |
| `capture-live.sh` | one-shot: bring-up → arm → capture → decode → PNG |
| `decode-bt656.py` | current decoder (mode 2 / true BT.656) |
| `probe.c`, `build.sh` | the libusb tool: firmware load, i2c, registers, capture |
| `decode-clean.py` | superseded: mode-1 gap filling + two-field merge |
| `decode2.py`, `decode-color.py`, `decode-field.py` | earlier decoders, reference |
| `color-test.sh`, `clock-tune.sh`, `geo-tune.sh` | register sweep harnesses |
| `snapshots/` | verification stills |
