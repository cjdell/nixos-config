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

Monitor keys: `1`/`2` switch input (Composite, S-Video), `Tab` cycles,
`g` colour/grey, `s` snapshot to `/tmp/pctv-snap-*.ppm`, `r` toggle raw BT.656
recording to `/tmp/pctv-rec-*.bt656`, space pause, `q`/ESC quit.  The active
input is named in an on-screen banner (and in the window title, with the live
field rate: ~50 fields/s = 25 interlaced fps for PAL); the controls hint is
shown for a few seconds after start and after each input change.

The input can also be chosen at launch, which is what the `.desktop` entry and
scripts use:

```sh
pctv-monitor -i svideo          # or -i composite
pctv-monitor -l                 # list the input names
PCTV_INPUT=svideo pctv-monitor  # same, via the environment
```

The card has one composite input (the yellow RCA) and one S-Video connector;
the other two RCAs are L/R audio.  Composite and S-Video share the same
CX25843 luma pin, so a source plugged into one connector still shows (luma
only) when the other input is selected; the CX25843 bring-up clears CKILLEN so
chroma is decoded on the selected input.

Headless checks (no display needed):

```sh
SDL_VIDEODRIVER=dummy PCTV_VERBOSE=1 ./pctv-monitor          # prints fps to stderr
PCTV_SNAP_AFTER=120 SDL_VIDEODRIVER=dummy ./pctv-monitor     # saves one frame, exits
# or drive the stream directly:
sudo ./pctv_probe stream composite1 > /tmp/live.bin          # raw mode-2 BT.656
```

Notes / current limits:

* Luma is correct and the picture is stable at the full 50 fields/s.  Chroma
  is now decoded (the bring-up clears the CX25843's CKILLEN, `0x401` bit 6,
  which the vendor default leaves on and which pins the picture to grey);
  residual rainbow fringing at chroma edges is the §14 resampling work, not
  yet applied here.
* **Audio is not implemented.**  The card's analog audio is digitised on-card
  but the only stream endpoint that ever delivers is `0x82`, and it carries
  raw BT.656 video; the vendor Windows BDA driver's audio framing (which is
  what splits audio out of the USB stream) is not decoded yet.  See TRUTH §9.
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
