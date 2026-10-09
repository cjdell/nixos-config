# pctv-linux — PCTV 320cx (dib0700) analog capture on Linux

Reverse-engineering notes and tooling for capturing **analog video** (composite
/ S-video) from a Pinnacle PCTV 320cx ExpressCard on Linux. The mainline
`dvb-usb-dib0700` driver is DVB-only and never enables the analog path, so the
hardware is driven directly over libusb. Full journey: **`FINDINGS.md`**.

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
entry, keeps the in-tree DVB driver off the card, and adds a udev rule:

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
the kernel module not being bound).

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
speakers**, `c` **MPEG-2 capture**, `r`
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
* ALSA is opened exclusively; if something else holds the device the panel
  shows the ALSA error instead of pretending there is silence.

### Automatic gain control (`A`, on by default)

The source level on this wiring is not stable: measured on the same input, the
minimum codec gain (-16 dB) put the peaks at -40 dBFS and the maximum (+30 dB
capture, +30 dB boost) drove it to full scale, and the level has been seen to
move ~20 dB inside a single second by itself.  So the AGC drives the **codec**,
never a software multiply: the meter, the verdict and the recorded file always
describe the same signal.

* Target: peaks near **-18 dBFS** (`AGC_TARGET_DBFS`), deliberately below the
  meter's -12..-3 manual zone.  A feedback loop has no lookahead on a live ADC,
  so the headroom is what keeps the source's step-ups out of the converter.
* Two loops.  **Attack**: a block arriving above -3 dBFS, or any clipped sample,
  drops 8 dB at once (up to ~16 times a second).  **Steady state**: every
  250 ms, move proportionally to the distance from the target (+6 dB only while
  more than 30 dB away, +2 dB nearer, dead band +-3 dB so it does not pump).
  It will not hunt a dead input (nothing above -75 dBFS).
* Two gain stages.  The fine `Capture` control is used first; when it runs out
  of headroom the AGC takes a `* Boost` step and re-centres the fine control,
  and when the fine control has drifted below 20 % of its range it trades a
  boost step back for headroom, because the boost stage is the noisier one.
* Measured on the live source (20 s, source swinging on its own): peaks held in
  -5..-18 dBFS with **12 clipped samples** in the file.  Triggering the attack
  on "approaching full scale" rather than "already clipped" is what took that
  from 4897 samples to 12 - waiting for the clip flag is 3 dB too late.
* `A` toggles it; `-`, `+` or `b` turn it off (the user's hand wins).  `--agc`
  / `--no-agc` set it from the command line.  Input, gain, boost **and** the
  AGC flag are all remembered in `~/.config/pctv-monitor/audio` (line 1 =
  input, line 2 = `<gain%> <boost step> <agc>`), so the next launch comes back
  where you left it - including AGC off, if that is where you left it.

### Input monitoring (`o`) - hear the gain before you record

`o` plays back, on the host's output, **exactly the samples the capture would
write** - the same buffer, unaltered, after the codec's gain and boost.  So the
meter and your ears judge the same signal, before committing to a recording.

* Toggled with `o` (or `--monitor` at launch).  The output stream is opened only
  while monitoring is on and closed again, so the desktop's audio is not held
  the rest of the time.
* It prefers the capture card's own playback stream (`hw:<card>,<device>`) and
  falls back to the default route.  Direct hardware on purpose: this box's
  PipeWire card profile was `Off`, which silently routes `default` to a **Dummy
  Output** - the monitor would have looked broken.  Diagnose with `wpctl status`
  (sink list) and `pw-dump <card-id>` (profile list), then select one, e.g.
  `wpctl set-profile 48 3` for *Analog Stereo Output*.  Pick an **output-only**
  profile, not Duplex: Duplex makes PipeWire grab the capture device that
  `pctv-monitor` needs exclusively - if that has happened, the panel and the log
  say `hw:0,0 busy - the audio daemon holds it; use an output-only profile
  (wpctl set-profile)`.  This profile choice is **not persisted** in the NixOS
  config yet, so it may need re-selecting after a reboot.
* If the codec's `Master` is muted or near silent (PipeWire leaves it wherever
  the desktop put it), monitoring raises it to a moderate level and says so, so
  a silent output is never mistaken for a dead input.
* Latency is roughly 60-100 ms (capture period + a 60 ms playback buffer).  That
  is fine for judging level, too slow to play along with.
* If the selected input is a **Mic** or **Internal Mic**, the panel says
  `feedback risk` - speakers into a mic will howl; use line in or headphones.

### MPEG-2 capture (`c`)

The deframed UYVY is piped to `ffmpeg` on stdin and the ALSA PCM on fd 3; the
result is a plain PAL-DVD-style program stream - `mpeg2video` 720×576
interlaced (top field first) at 25 fps, `-b:v`/`-maxrate` 6000k, `-bufsize`
1835008, `-g 15`, `+ilme+ildct`, 4:3, plus `mp2` 48 kHz stereo 192k.

* Files land in `~/Videos/pctv-cap-<timestamp>.mpg` (`--out-dir`,
  `PCTV_OUT_DIR`, falls back to `/tmp`); bitrate via `--bitrate <kbps>` /
  `PCTV_MPEG2_BITRATE`.
* The encoder starts on the **first decoded frame**, not on the key press, so
  both streams share PTS 0 - otherwise a capture started while the decoder is
  still hunting carries up to 8 s of extra audio (the lock poll, see below).
* **Recording is obvious on screen**: a 4 px red border around the frame, a
  large `REC mm:ss.t` badge with a dot blinking once a second, and a line with
  frames, bytes, the drop counters and the encoder queue occupancy.
* The encoder is fed from a **4-frame ring owned by a writer thread**, never
  from the main loop.  Writing an 829 KB UYVY frame inline meant the display
  waited on the encoder - and while the main loop waits, nothing drains the
  probe either, so the whole pipeline hiccups.  If the ring fills, the newest
  frame is dropped whole and counted: an encoder that cannot keep up shows up
  as counted frame drops (with the video track ending up shorter than the
  audio) instead of a stalling picture.
* Both pipes are `poll()`ed and the audio pipe is non-blocking: a slow encoder
  costs counted frame drops, never a wedged GUI or a stalled USB drain.
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

`PCTV_VERBOSE=1` prints one line per second: the codec's gain, the meter peaks,
the clip count, the byte counters, the encoder queue occupancy, and the **worst
main-loop gap of that second broken down into `parse` / `feed` / `render`**.
That breakdown is the instrument for "the picture froze": a large `render` gap
is the display path, a large `parse` gap is the incoming stream, and a `feed`
gap or a full queue means the encoder is not keeping up.  `PCTV_HELP=1` starts
with the help overlay up (it is normally toggled with `H`).

With **no source playing** the decoder's lock poll (`poll for a real lock`,
16 × 500 ms in `analog2_bringup`) delays the first data by ~8 s; the monitor
just shows no picture until then, and captures queued with `--capture` start at
the first frame.  Settle time after a cold plug is another ~10 s (TRUTH §1).

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
* The child needs raw USB.  It is launched via `sudo -n`; a udev rule (below)
  would remove that requirement.

## The driver — `driver/`

The reverse-engineered bring-up is now a real kernel module: **`pctv320cx.ko`**,
Rust core + C V4L2 glue, in `driver/`.

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

Deploy on the MacBook (the host with the ExpressCard slot) — `nixos-module.nix`
adds the module to `boot.extraModulePackages` / `boot.kernelModules`, pulls in
linux-firmware (`dvb-usb-dib0700-1.20.fw`, `v4l-cx25840.fw`) and keeps
`dvb_usb_dib0700` off the device. It is enabled in
`machines/macbook-pro-2009/default.nix`; the Win7-VM passthrough that used to
own the card is retired.

Module metadata after a successful build:

```
alias:   usb:v2304p022Ed*…      depends: videodev,videobuf2-v4l2,videobuf2-common,videobuf2-vmalloc
firmware: dvb-usb-dib0700-1.20.fw, v4l-cx25840.fw      parm: debug (u32)
```

**Status: builds clean against 7.2.3 (the MacBook's kernel); not yet run against
hardware.** The bring-up sequence, the mode-2 arm and the deframer are direct
transcriptions of what `capture-live.sh` proved on the real card; the first
on-hardware run is the next step (`dmesg`, `v4l2-ctl --all`, then
`ffmpeg -i /dev/video0 …`).

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
| `driver/` | the kernel module (Rust core + C V4L2 glue), see above |
| `nixos-module.nix` | `hardware.pctv320cx.enable` — deploy the module |
| `capture-live.sh` | one-shot: bring-up → arm → capture → decode → PNG |
| `decode-bt656.py` | current decoder (mode 2 / true BT.656) |
| `probe.c`, `build.sh` | the libusb tool: firmware load, i2c, registers, capture |
| `decode-clean.py` | superseded: mode-1 gap filling + two-field merge |
| `decode2.py`, `decode-color.py`, `decode-field.py` | earlier decoders, reference |
| `color-test.sh`, `clock-tune.sh`, `geo-tune.sh` | register sweep harnesses |
| `snapshots/` | verification stills |
