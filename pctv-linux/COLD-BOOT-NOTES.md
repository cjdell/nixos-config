# Cold-boot bring-up notes — userspace PCTV 320cx (macbook-pro-2009)

**Written:** 2026-10-08 ~19:30 BST, before the first cold boot of the new
userspace-only config.  **Commit:** `f70a608` — "pctv-linux: add userspace live
monitor (libusb + SDL2), drop kernel module".  **Host:** `macbook-pro-2009-nixos`,
kernel 7.2.9, ExpressCard slot `0000:00:1c.3` (EHCI bus 2, port 3).

Read `TRUTH.md` first (it is the authority); this file is the cold-boot runbook
for what we just changed.

---

## 0. RESULT — 2026-10-08 ~19:25 cold boot: **it did not work**, for a fixable
and a fundamental reason

Run against kernel 7.2.9, card cold (`GET_VERSION` → `Pipe error`).

**Finding 1 (bug, fixed in `package.nix`): the GUI never even saw the firmware
path.** `pctv-monitor` sets `PCTV_PROBE`/`PCTV_BRIDGE_FW`/`PCTV_DECODER_FW`,
but its child launches the probe through `sudo -n`, and sudo's `env_reset`
**drops every `PCTV_*` variable**. `probe.c` then falls back to the relative
path `firmware/dvb-usb-dib0700-1.20.fw`, so the cold-boot log is:

```
stream: bridge not running -> downloading firmware/dvb-usb-dib0700-1.20.fw
open fw: No such file or directory
stream: bridge firmware download failed
   (then every ctrl_out/ctrl_in -> Pipe error)
```

Only `pctv-monitor` was wrapped (to set `PCTV_PROBE`); `pctv_probe` itself was
not, and `PCTV_PROBE` pointed at the *raw* binary. Fix: wrap `pctv_probe` too
(so `sudo -n <wrapper>` restores the firmware paths), not just the GUI.
(Confirm with `sudo env` — `sudo -n env | grep -i pctv` prints nothing.)

**Finding 2 (fundamental, open): the userspace cold download does not boot the
bridge.** With the path supplied explicitly:

```
firmware: 1610 record(s) written
jumpram -> 0x70000000 ok
-- GET_VERSION --
  ctrl_in rq=0x15 ... -> Pipe error
GET_VERSION failed -> device is COLD (no firmware running)
```

This was checked both in a fresh process and inside the *same* process
(`pctv_probe init`, which downloads and then immediately re-reads
`GET_VERSION`), so it is not a handle-close artefact. It confirms the previous
`ram=0x00000001` ROM-idle observation (TRUTH §7) from a **true-cold** state and
matches HANDOVER's 14:20 result: **bytes are identical to the kernel's, but the
kernel boots the card and userspace does not.** Do not keep re-testing the blob
shape.

**The kernel download can fully boot the card** — `logs/kernrevive-1791480502/`
(t ≈ 14001 s) shows `cold state → downloading firmware → firmware started
successfully → registering adapter 0 frontend 0 (**DiBcom 7000PC**)`, and once
like that it survives unbind (t ≈ 14120: rebind is `warm state`, no download).
But it is **not reliable**: binding `dib0700` here produced `warm state` with
`stk7700ph_frontend_attach: i2c_enumeration failed`, i.e. the bridge firmware
did not actually take — the same half-booted state klog t ≈ 13866. Which state
you get is the unresolved ROM sub-state question (TRUTH §9.2).

**Consequences / what to do**

1. The stated goal (userspace-only, kernel driver blacklisted) **cannot
   cold-boot the card**. The only downloader known to work is the kernel's.
2. To revive the card now: **physical pull ≥ 60 s**, re-insert, then either
   (a) let the kernel download and hand off — but note detaching `dib0700`
   after a *successful* boot keeps the bridge warm while detaching after a
   half-boot resets it — or (b) `insmod` the in-tree modules (§5.3).
   The card is currently in the half-booted state; a pull is required.
3. Reliable cold boots need an architecture change (let `dvb_usb_dib0700` do
   the download, with uncompressed firmware + `firmware_class.path`, and keep
   the userspace monitor on the warm bridge). Decide before more userspace
   download work.

> Operational trap hit during this session: a `pctv_probe fw2` left running
> holds interface 0 via usbfs and (a) makes `lsmod`-checking misleading and
> (b) blocks `dib0700` from binding with `Device or resource busy`. `pgrep -a
> pctv_probe` before binding anything.

---

## 1. What changed, and why a cold boot is interesting

Before: the out-of-tree **`pctv320cx.ko` V4L2 kernel module** warmed the card
(it downloads the DiB0700 bridge firmware in probe/`dvb-usb`-style cold start)
and exposed `/dev/video2`.

Now (`hardware.pctv320cxLive`, `pctv-linux/live-module.nix`):

* the kernel module is **no longer built or loaded**;
* `dvb_usb_dib0700` is **blacklisted** (`boot.blacklistedKernelModules` +
  the host's hard `install dvb_usb_dib0700 false`);
* `pctv-monitor` (SDL2 GUI) spawns `pctv_probe stream <input>` (libusb), which
  does the whole bring-up and streams BT.656.

**Consequence:** on a cold boot **nothing else touches the card** — the first
vendor request comes from `pctv_probe`.  So the `pctv_probe` **userspace bridge
firmware download is now the only downloader**.  That path is the thing this
cold boot tests.

> TRUTH §2/§7: the card has no self-booting firmware.  The kernel's download
> **from true cold** is the only one with a long track record; a **userspace**
> download was previously observed **not** to boot the card when it was in the
> `ram=0x00000001` ROM-idle state.  From a *true cold* state (GET_VERSION does
> not answer) the userspace download is **untested** in this config.  If the
> card stays cold, use the recovery ladder in §5.

---

## 2. The risky bits (short list)

1. **Cold bridge + userspace download.**  `cmd_stream` calls `bridge_ram()`; if
   it is not `0x00010200` it calls `download_firmware()` on the store blob.
   Watch for `stream: bridge not running -> downloading …` then
   `after download ram=0x00010200 -> RUNNING`.  If it stays cold, §5.
2. **Which post-pull state you get.**  TRUTH §4: after a pull the card comes up
   in one of two states non-deterministically — GET_VERSION answering with
   `ram=0x00000001` (ROM idle), or not answering at all.  Our code tries to
   download in **both** cases (anything != `0x00010200`).
3. **First accessor matters.**  A half-booted bridge can wedge if something
   pokes it too early.  The new config deliberately leaves it to `pctv_probe`
   (this is what `first-touch.sh` was testing).  Don't run `pctv_probe`
   sub-commands (including `ver`) against the card while the GUI is streaming —
   `pctv_probe` opens and claims interface 0, which kills the running stream.
4. **Mode-2 arm ordering.**  The bridge only accepts `ENABLE_VIDEO mode 2`
   (`0f 12 01 00`) after an off→on transition.  `cmd_stream` brings up with
   `0f000000` then arms `0f120100` (up to 8 tries).  If you ever see
   `stream: WARNING: mode-2 arm kept failing`, the stream will be non-BT.656.
5. **Stale kernel module from the previous generation.**  A `nixos-rebuild
   switch` does **not** unload `pctv320cx`.  A cold boot is exactly what clears
   it.  If `/dev/video2` exists and `lsmod | grep pctv320cx` is non-empty, the
   old module is still around (harmless for the GUI run *as root* — libusb
   detaches it — but it breaks a no-sudo run).

---

## 3. Expected happy path after install

```sh
just rebuild            # macbook has no autoRollback → no nixos-confirm needed (verify!)
sudo reboot
# after boot:
lsusb -d 2304:022e                    # device present
lsmod | grep -c pctv320cx             # 0  (module gone)
ls /dev/video2                        # "No such file or directory"  (expected)
pctv-monitor                          # window appears, live video
```

`pctv_probe` and `pctv-monitor` will be on `PATH` after the rebuild
(`environment.systemPackages` from the module).  The wrapper sets
`PCTV_PROBE`, `PCTV_DECODER_FW`, `PCTV_BRIDGE_FW`; with the default
(`noSudo = false`) the GUI runs the probe through `sudo -n`.

---

## 4. Diagnosis — run in this order

```sh
# a) is the device there, and what claimed it?
lsusb -d 2304:022e
lsmod | grep -E 'pctv320cx|dvb_usb|dib0700'
ls /dev/video2 2>&1

# b) bridge state (the single most useful reading).  This opens+claims the
#    interface, so stop pctv-monitor first.
sudo pctv_probe ver
#   no answer            -> truly COLD (nothing running)
#   ram=0x00000001       -> ROM idle (TRUTH calls this "warm"; no firmware)
#   ram=0x00010200       -> firmware 1.2.0 RUNNING  (healthy)
#   hw=0x66 rom=0x11     -> constant in every state

# c) decoder reachable? (only meaningful once the bridge is warm)
sudo pctv_probe cxr 0x100 1           # expect cx 100 = 34  (CX25843, id 0x8434)
sudo pctv_probe cxdump | grep -E '0x40d|0x40e'
#   0x40e bit5 (0x20) set -> signal present; clear -> no source (or loose)

# d) bridge cold?  watch the userspace download attempt
sudo pctv_probe stream composite1 > /tmp/live.bin 2>/tmp/live.err
#   stderr should show:  bridge not running -> downloading …
#                        after download ram=0x00010200 -> RUNNING
#                        decoder: … -> SIGNAL PRESENT ; arm -> ok
grep -E 'bridge|decoder:|arm|WARNING|error' /tmp/live.err
```

**Full end-to-end check with no display** (best single test):

```sh
PCTV_SNAP_AFTER=120 SDL_VIDEODRIVER=dummy pctv-monitor   # saves one frame, exits
ls -l /tmp/pctv-snap-*.ppm                               # ~1.24 MB = full 720x576
```

**Is the stream really BT.656 mode 2?**  In mode 2 each 1728-byte line carries
an EAV *and* a SAV, so the `FF 00 00` sync words are ~864 B apart
(`size / count(FF0000) ≈ 864`).  Mode 1 is ~1444 B; no syncs at all = the arm
/ decoder never enabled.  Quick check (python from nixpkgs):

```sh
nix shell --impure --expr 'with import <nixpkgs> {}; python3.withPackages (p: [p.numpy])' \
  --command python3 -c "
import numpy as np
d=np.fromfile('/tmp/live.bin',dtype=np.uint8)
m=(d[:-2]==0xFF)&(d[1:-1]==0x00)&(d[2:]==0x00)
print('size',d.size,'sync',int(m.sum()),'spacing',round(d.size/max(1,int(m.sum())),1))"
```

---

## 5. Recovery ladder (cold card)

### 5.1 First, just retry the userspace download
`pctv_probe stream` already does this.  You can do it by hand and re-check:

```sh
FW=/nix/store/njxlajsy1rfj7wb4sdvdbwg28m8n4wak-libreelec-dvb-firmware-1.5.0/lib/firmware
sudo pctv_probe fw $FW/dvb-usb-dib0700-1.20.fw   # bulk EP1 download + jumpram
sudo pctv_probe ver                               # want ram=0x00010200
```
(If the store path hash changed after a rebuild, use the wrapper's env:
`sudo pctv_probe fw "$PCTV_BRIDGE_FW"` after `export $(pctv-monitor --help >/dev/null; ...)`
— or just `nix-build -E 'with import <nixpkgs> {}; callPackage ./pctv-linux/package.nix {}'`
and take the blob from `libreelec-dvb-firmware`.)

### 5.2 USB port reset
```sh
sudo pctv_probe reset    # one of the few resets the slot offers
sudo pctv_probe ver
```
EHCI can be left wedged by a bad detach (`device descriptor read/64, error -110`);
recover by unbind/bind of `0000:00:06.0`/`0000:00:06.1` (see HANDOVER
"Controller recovery").

### 5.3 Fall back to the *kernel* bridge-firmware download (known-good from cold)
The in-tree `dvb_usb_dib0700` reliably boots the bridge from cold, but
`modprobe` is blocked by the host (`install … false`) — use `insmod` (TRUTH §3).
The NixOS firmware is `.zst`, which the kernel cannot read, so decompress first:

```sh
sudo mkdir -p /tmp/pctv-fw
cd /run/current-system/firmware
for f in dvb-usb-dib0700-1.20 v4l-cx25840 xc3028-v27; do
  [ -e "$f.fw.zst" ] && nix shell nixpkgs#zstd --command zstd -dc "$f.fw.zst" \
    | sudo tee /tmp/pctv-fw/$f.fw >/dev/null
done
echo /tmp/pctv-fw | sudo tee /sys/module/firmware_class/parameters/path

M=/run/booted-system/kernel-modules/lib/modules/$(uname -r)/kernel/drivers/media
sudo insmod $M/dvb-core/dvb-core.ko.xz
sudo insmod $M/usb/dvb-usb/dvb-usb.ko.xz
sudo insmod $M/usb/dvb-usb/dvb-usb-dib0700.ko.xz
```
If the card is warm, it may classify as warm and skip the download.  To force a
true-cold download you must power-cycle the card: **pull the ExpressCard for
≥60 s**, re-insert, and let the kernel catch it cold
(`found a 'Pinnacle Expresscard 320cx' in cold state` → `downloading firmware` →
`firmware started successfully`).  Then `pctv_probe stream` (as root) can
`libusb_detach_kernel_driver` and take over.

### 5.4 Physical pull (the universal reset)
The ROM's I2C engine can be wedged by an invalid I2C probe (`rq 0x02 wValue 0`).
Only a **physical pull ≥ 60 s** clears it — a USB port reset / `authorized`
0→1 toggle does **not**.  See TRUTH §4 "Wedge rule".

### 5.5 Re-enable the old V4L2 driver (last resort / to compare)
Edit `machines/macbook-pro-2009/default.nix` back to the kernel module and
rebuild (this builds a kernel module — heavy, dispatched to zen3):

```nix
imports = [ ../../pctv-linux/nixos-module.nix ];
hardware.pctv320cx.enable = true;
```
Then `just rebuild`, `sudo nixos-confirm` **only if** the host turns out to have
autoRollback (it should not).

---

## 6. Symptoms → cause → fix

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `lsusb` shows nothing | slot/power, or wedged EHCI | reseat; check `dmesg`; §5.2 |
| `pctv_probe ver` no answer and download fails | cold; userspace download didn't boot | §5.3 (kernel download), §5.4 |
| `ver` shows `ram=0x00000001` and stays | ROM idle; download not booting | §5.3 |
| `LIBUSB_ERROR_BUSY` / "claim if0" | another probe/GUI running, or kernel module bound | kill the other; `lsmod`; reboot |
| `decoder: … no signal` (`0x40e` bit5 clear) | no source, or loose connector | wiggle / reseat the source (we did this successfully 2026-10-08) |
| `cx 100 = 00` (decoder answers but reads 0) | decoder not powered/clocked (TRUTH §6) | GPIO sweep: `sudo pctv_probe gpiosweep 0x09`, then re-probe |
| `arm -> Pipe error` repeatedly | off→on not done, or ROM wedge | `cmd_stream` retries; else §5.4 then retry |
| Stream flows but no `FF 00 00` / black frames | arm/mode failed, or no signal lock | check `arm -> ok`, `0x40e` bit5, §4 |
| GUI exits immediately | child died (USB) or SDL display | run `pctv-monitor` from a terminal; read stderr; `SDL_VIDEODRIVER=dummy` to test headless |
| `pctv-monitor: command not found` | host not rebuilt yet | `just rebuild`, or run from the store path |

---

## 7. Useful facts / paths

* **Package** (rebuild changes the hash): `nix-build -E 'with import <nixpkgs> {}; callPackage ./pctv-linux/package.nix {}'`
  → `$out/bin/{pctv_probe,pctv-monitor}`; the GUI wrapper exports
  `PCTV_PROBE`, `PCTV_DECODER_FW`, `PCTV_BRIDGE_FW`.
* **Firmware (uncompressed, proven variant = libreelec):**
  `/nix/store/njxlajsy1rfj7wb4sdvdbwg28m8n4wak-libreelec-dvb-firmware-1.5.0/lib/firmware/`
  — `v4l-cx25840.fw` (16382 B, md5 `b3704908…`) and `dvb-usb-dib0700-1.20.fw`
  (33768 B).  **Do not** use `linux-firmware`'s `v4l-cx25840.fw` — it differs.
  NixOS's `/run/current-system/firmware/*.fw.zst` are **not** readable by the
  kernel's `request_firmware` either (TRUTH §7).
* **Config:** module `pctv-linux/live-module.nix` (`hardware.pctv320cxLive`),
  enabled in `machines/macbook-pro-2009/default.nix`.  `noSudo = true` bakes in
  `PCTV_NO_SUDO=1` and relies on the module's udev rule
  (`GROUP="video", MODE="0660"`) plus no bound kernel driver.
* **GUI controls:** `1`–`4` input, `g` grey, `s` snapshot → `/tmp/pctv-snap-*.ppm`,
  `r` record raw BT.656 → `/tmp/pctv-rec-*.bt656`, space pause, `q`/ESC quit.
* **Headless env vars:** `SDL_VIDEODRIVER=dummy`, `PCTV_VERBOSE=1` (fps to
  stderr), `PCTV_SNAP_AFTER=N` (write one PPM then exit).
* **Display on this host:** Wayland (kwin) + XWayland `:0`; from a plain shell
  `DISPLAY=:0 XAUTHORITY=/run/user/1000/xauth_*`.  Running from the desktop
  session needs none of that.
* `/tmp/pctv-fw` and all `/tmp` scratch are gone after a cold boot — the Nix
  package does not depend on them.

---

## 8. Known non-issues / current limits

* **Chroma fringing** (rainbow edges) is expected; the §14 chroma work is not in
  the monitor yet.  Luma is correct.
* **PAL only** (720×576).  NTSC needs a 720×480 path.
* **`0x40e = 0x0a` with no source** is normal; the decoder free-runs and emits
  valid **black** frames (not zero bytes).  `0x40e` bit5 set is what matters.
* The default config uses `sudo -n` for the probe; the GUI itself runs as the
  user, so the SDL/display side is unaffected.

---

## 9. If it all works (what "good" looks like)

```
stream: bridge firmware already running        (warm)  — or downloaded+RAM=0x10200 (cold)
decoder: 0x40d=94 0x40e=7f -> SIGNAL PRESENT
arm -> ok
stream: ep 0x82, 24 URBs x 32768 B -> stdout
```
and `pctv-monitor` shows the picture at ~50 fields/s (25 interlaced fps).  Then
this file's job is done — fold any new findings back into `TRUTH.md`.
