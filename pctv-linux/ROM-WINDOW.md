# ROM-window catcher — how to interrogate the cold PCTV 320cx

`./rom-window.sh` wraps a new `pctv_probe romwin` command that watches for the
DiB0700 bridge to answer on EP0, and the moment it does, dumps everything we have
never been able to read: both `GET_VERSION` forms, the full config EEPROM,
`GET_GPIO`, and the vendor-request map.

It is **read-only** against the card's persistent storage. It never writes the
EEPROM. The only traffic it sends is `GET_VERSION`, `GET_EEPROM`, `GET_GPIO`, the
vendor-request probe, and the ordinary non-persistent RAM firmware download.

---

## 0. RESULT of the 2026-10-08 15:53 run — read this first

The run worked: **19 ROM windows** in 4 minutes (`logs/rom-window-1791471238/`),
and the bridge answered **`GET_EEPROM` too** — 2048 reads per window, zero
errors, and all 19 dumps byte-identical (`md5 b0100150…`). That is the first
EEPROM content ever read off this card. Four things were settled:

1. **The ROM window is real and repeatable.** `GET_VERSION` →
   `hw=0x00000066 rom=0x00000011 ram=0x00000001 fwtype=0x00000000` on *both*
   recipients (recipient 0 works here too — the "recipient 0 only" note in
   FINDINGS §15 was an artifact of the state, not of the request form).
2. **`ram=0x00000001` is a static ROM constant, not a "firmware is running"
   flag.** It is unchanged before the download, after a successful download, and
   after `jumpram 0x70000000 -> ok`. So "the download is accepted" carries no
   information: the ROM reports its own version word either way.
3. **The EEPROM read is a sliding window and the old index was wrong.** The 8
   bytes returned start at EEPROM byte **`wIndex >> 8`** — the ROM's index
   register is the *high byte* of `wIndex`, it is **8 bits** wide, and it wraps
   (verified at 12 index points: `wIndex` 0x0000/0x0008/0x00ff all return byte 0,
   0x0100 returns byte 1, 0x1000 byte 16, 0x2000 byte 32, 0xffff byte 255 then
   wraps to 0). `eepromdump`'s `wIndex = offset` therefore re-read the same byte
   32 times: the 16 KiB "full dump" was really **bytes 0..70**. Fixed in
   `eepromdump` (index = `off<<8`, capped at 256 B) — and `wIndex` being 16 bits
   caps the reachable EEPROM at **256 bytes**, which is why `eepromwin` also maps
   the other `wValue`/`wIndex` forms (2-byte index? page bits in the I2C address
   byte?) — that is the only thing between us and the rest of the image.
4. **The wedge has a mechanism.** The vendor-request map probe (which sends
   `rq 0x02` with `wValue 0`, i.e. I2C address byte `0x00`) **killed the EEPROM
   read service** — from that moment `c4 02 01a0` STALLs forever while
   `GET_VERSION` keeps answering, and a USB port reset does not help. That is the
   mechanism behind the old "probing every request number wedges the stick"
   note: it wedges the ROM's **I2C engine**, not the whole device. The map is now
   opt-in (`--map`); the default snapshot no longer self-sabotages.

The reconstructed EEPROM (bytes 0..71, from the sliding windows — all 19 dumps
agree, and 0 of 2048 blocks disagreed with their group):

```
000: d0 04 23 2e 02 00 01 05 04 03 09 04 20 03 50 69  |..#......... .Pi|
010: 6e 6e 61 63 6c 65 20 73 79 73 74 65 6d 16 03 50  |nnacle system..P|
020: 43 54 56 20 33 32 30 63 78 16 03 30 30 30 30 30  |CTV 320cx..00000|
030: 30 30 31 30 30 02 03 02 03 1c 06 06 75 30 05 37  |00100.......u0.7|
040: 37 30 30 30 50 08 15 02                          |7000P...|
```

Decoded: `d0` = the marker the Windows driver reads at cold start (`c4 02 01a1`,
len 1 → `d0`); `04 23 2e 02` = VID 0x2304 / PID 0x022e little-endian; `00 01` =
bcdDevice 0x0100; `05` = string count; then the string-descriptor headers with
**ASCII** payloads (`04 03 09 04` = LANGID 0x0409, `20 03`+"Pinnacle system",
`16 03`+"PCTV 320cx", `16 03`+"0000000100", two empty `02 03`), then `1c 06 …`
and a model string ending `37 37 30 30 30 50` = **"7700P"** (the same 7700 the
vendor's Windows driver is named after: `Ltn_hyd7700pc_64.sys`).

So the EEPROM is **not blank and not `ff`** — its descriptor block is intact and
readable *right now*, in the failed state. "The self-boot image is gone" is no
longer the leading hypothesis on the evidence available; what is still unknown is
bytes **72..255** (where a firmware-record header would live) and anything past
255. Getting those needs the I2C service restored — i.e. a **physical pull
≥ 60 s** — and then `./rom-window.sh --eeprom` (see §3.4).

### 0.1 …and the pull was done at 18:01: the image is not there (FINDINGS §16.7)

`logs/eeprom-window-1791478844/eeprom-1791478863.bin`, 32/32 windows, 0 bad:
the config block ends at **0x4a** and **bytes 0x4b..0xff are all `ff`** (179 of
256 bytes erased; strays only at `0x7f=e3`, `0x80=00`). A second index form,
`wValue 0x02a0` (**same 8-bit index, +1 offset, no wrap**), reaches **byte 256 —
also `ff`** — which is exactly where an aligned firmware image would have to
start. No form reaches further (`0x03a0/04a0/08a0/10a0/20a0` stall).

**Verdict: EEPROM alive, config intact, boot ROM alive, firmware image absent, and
a clean power cycle still yields `ram=0x00000001`.** The card is bricked at the
boot-image level; nothing host-side can fix it. The only further step (writing
the image into the EEPROM with the ROM's I2C write, `rq 0x01`) is destructive and
was deliberately **not** taken — it needs an EEPROM record format we do not have
and would risk the config block that still makes the card enumerate.

---

## 1. Why this exists (30-second recap)

The card's firmware normally **self-boots from a config EEPROM** on power-up
(healthy: `GET_VERSION` → `ram=0x00010200`). Since **Oct 7 21:58** it has never
done so again:

* `GET_VERSION` usually **stalls** (EPIPE) → no firmware, and the mask ROM is not
  servicing EP0 either.
* Occasionally the bridge answers with `ram=0x00000001` → the **mask ROM** is
  running, but no image (EEPROM or host-downloaded) executes.
* A host firmware download + `jumpram 0x70000000` is **accepted** (bulk transfers
  ACK), but the firmware never answers afterwards.
* The **Windows driver sends byte-identical traffic and fails identically**
  (`logs/win7-vs-linux-20261008.md`), so this is card-side, not host-side.
* A physical power cycle does **not** clear it — unlike the old port-reset-
  recoverable wedge (FINDINGS §7.1).

This tool is the one free experiment left: **catch the ROM window and ask the
chip questions**, to tell "the self-boot image is gone" apart from "the 8051/RAM
no longer executes anything".

---

## 2. Build

```sh
cd ~/nixos-config/pctv-linux
./build.sh          # rebuilds ./pctv_probe with the `romwin` / `eepromdump` commands
```

Quick check:

```sh
./pctv_probe 2>&1 | grep -E 'romwin|eepromdump'
```

---

## 3. Run it

### 3.1 Get the card onto the host, first

`pctv_probe` cannot open the card while qemu holds it. If the `win7` VM is
running with the card attached:

```sh
# stop the guest from re-claiming it, then detach
virsh -c qemu:///system detach-device win7 /tmp/pctv-hostdev-vidpid.xml --live
```

If the detach leaves the EHCI/OHCI controller wedged (`device descriptor read/64,
error -110`), recover it — see §6.

### 3.2 Block the kernel driver

`udev` modalias auto-loads `pctv320cx` ~0.2 s after enumeration, and it will run
its own download and steal the window. **`blacklist` does not stop modalias
autoload**; use an install override (temporary — it disappears on
`nixos-rebuild switch`):

```sh
echo "install pctv320cx $(command -v false)" | sudo tee /etc/modprobe.d/99-pctv-test.conf
sudo rmmod pctv320cx dvb_usb_dib0700 2>/dev/null
sudo modprobe pctv320cx     # MUST fail — that is the check that it is really off
```

`rom-window.sh` does the `rmmod` for you and warns if it is still loaded.

### 3.3 The run

```sh
# 30-minute watch: provoke with the vendor firmware download the Windows driver uses
sudo ./rom-window.sh 1800 --hold
```

`--hold` prints the pull/re-plug instructions and expects you to power-cycle the
card **during** the run (pull ≥ 60 s — a short hot-swap does not drop the slot
rails). The watcher keeps waiting and catches whatever the card does first.

Useful variants:

| command | what it does |
| --- | --- |
| `sudo ./rom-window.sh 1800 --hold` | default: download-provoke + watch (best first try) |
| `sudo ./rom-window.sh 600 --reset-every 20` | also USB-port-reset every 20 iterations |
| `sudo ./rom-window.sh 300 --no-fw` | passive watch only (no firmware sent) |
| `sudo ./rom-window.sh 60 --max 3` | stop after 3 captured windows |
| `sudo ./rom-window.sh --eeprom 3600 --hold` | **watch for the (rarer) `GET_EEPROM` read service** and grab the whole 256-byte image + the index-form map the moment it answers — this is the one to run after a pull |
| `sudo ./rom-window.sh 600 --map` | also take the vendor-request map per window — **wedges the I2C/EEPROM service**, only do it *after* the EEPROM grab |

Everything is logged under `logs/rom-window-<epoch>/` (or `logs/eepromwin-<epoch>/`).

### 3.4 The EEPROM window (`--eeprom` / `pctv_probe eepromwin`)

Measured 2026-10-08: the ROM answers `GET_VERSION` and `GET_EEPROM` **separately**.
`GET_VERSION` has been answering for hours; the `GET_EEPROM` service was alive for
~4 minutes and has been dead (EPIPE) ever since the map probe. So the EEPROM read
is a *rarer* window than the ROM window, and polling for it is a separate job:

```sh
sudo ./rom-window.sh --eeprom 3600 --hold      # then pull the card >= 60 s and re-insert
```

The instant `c4 02 01a0` answers, `eepromwin` takes, in one burst: both
`GET_VERSION` forms, the **full 256-byte image** (correct index, hex-dumped and
saved as `eeprom-<epoch>.bin`), the byte-255 wrap cross-check, and the **safe
extended probe** — `wValue 0x02a0` at `wIndex` 0x0000/0100/0200/1000/2000/fe00/
ff00 (the +1, no-wrap law; `ff00` reads byte 256) plus an I2C-in to the demod
address (`0x0180`/`0x0182`). The destructive invalid-address sweep is opt-in
(`--map`).

**Operational notes, learned the hard way:**

* The window after a pull lasts **one burst** — it died again right after the
  probes. So the order inside `eepromwin` is image → safe probes → (optional)
  destructive sweep, and `--max 1` is the right default.
* Each iteration sends the firmware download (~0.8 s). For the fastest possible
  poll use `--no-fw` (~0.15 s per iteration).
* A pull is the **only** known way to restore the I2C engine: port reset, usbfs
  `authorized` 0→1 and EHCI-level resets all leave it wedged.

---

## 4. What you get

```
logs/rom-window-<epoch>/          (or logs/eepromwin-<epoch>/ with --eeprom)
  romwin.log / watch.log  the console log (every window, every dump)
  eeprom-windowN.bin      EEPROM image read during ROM window #N (256 B, correct index)
  eeprom-<epoch>.bin      EEPROM image grabbed by eepromwin (256 B)
  raw-bus2.bin            usbmon capture if you started one (parse with ./parse.sh)
  dmesg-before.txt
  dmesg-during.txt        only the lines generated during the run
  dmesg-after.txt
```

A caught window looks like:

```
*** ROM WINDOW #1 at 21:14:03 ***
  [21:14:03] GET_VERSION recipient0 -> ok  de ad be ef ...
    hw=0x00000066 rom=0x00000011 ram=0x00000001 fwtype=0x00000000
  [21:14:03] GET_VERSION recipient4 -> EPIPE
  [21:14:03] GET_GPIO_VAL -> ok  ...
  [21:14:03] EEPROM dump -> logs/rom-window-.../eeprom-window1.bin
  eepromdump: 32 window(s) ok, 0 bad, bytes 0..ff (saved)
  wrap check @255 -> ok  ff d0 04 23 2e 02 00 01
  [21:14:03] vendor request map (recipient 4, IN, 0x00..0xff): SKIPPED (use --map)
```

---

## 5. How to read the result

| `ram=` in the window | meaning | what it tells us |
| --- | --- | --- |
| `0x00010200` | **self-booted firmware** | the card is actually alive — stop here, go capture video |
| `0x00000001` | **mask ROM** | the 8051 runs its ROM but no image executes |
| no window at all | ROM not servicing EP0 | the 8051 is not running even its ROM |

Then look at the EEPROM image (`eeprom-windowN.bin` / `eeprom-<epoch>.bin`,
256 bytes — the ROM index is 8-bit, that is all that is reachable):

| EEPROM content | conclusion | next step |
| --- | --- | --- |
| mostly `00` / `ff` | **self-boot image is gone/corrupt** — explains why a power cycle never helps | recovery would mean rewriting the EEPROM (a *separate*, riskier step — not implemented here) |
| plausible data (matches the firmware record format) | EEPROM is intact → the fault is in the **8051/RAM execution or its supply** | hardware: rails/regulator, or replace the card |

**Status of that test:** bytes 0..71 are *plausible data* (see §0) — the
config/descriptor block is intact. The test is therefore **half done**: what
decides it is bytes 72..255 (a firmware-record header, or `00`/`ff` padding), and
for that the I2C service has to be restored by a physical pull.

Whatever the outcome, **paste `romwin.log`/`watch.log` (the window section) and
`dmesg-during.txt` into the next session** — that is the whole point of the run.

---

## 6. Controller recovery (needed after some qemu detaches)

The MCP79 EHCI/OHCI does not always re-arm after a qemu USB hostdev teardown and
the port then logs `device descriptor read/64, error -110` forever. Recovery that
works:

```sh
sudo sh -c 'echo 0000:00:06.0 > /sys/bus/pci/drivers/ohci-pci/unbind'   # background; may hang ~60 s
sudo sh -c 'echo 0000:00:06.1 > /sys/bus/pci/drivers/ehci-pci/unbind'   # background; may hang ~60 s
sudo sh -c 'echo 0000:00:06.0 > /sys/bus/pci/drivers/ohci-pci/bind'
sudo sh -c 'echo 0000:00:06.1 > /sys/bus/pci/drivers/ehci-pci/bind'
```

Run each with `&` and wait; the devices come back (`usb4`, `usb2`). Bus 2 = EHCI
(high-speed), bus 4 = OHCI (full-speed, the card falls back to it if EHCI is
unbound).

---

## 7. Manual / lower-level use

`romwin` is a front-end; the pieces are usable directly:

```sh
sudo ./pctv_probe ver                       # one GET_VERSION (recipient 4)
sudo ./pctv_probe raw in 0x15 0 0 16        # GET_VERSION, recipient 0
sudo ./pctv_probe eepromdump 256 /tmp/e.bin # EEPROM bytes 0..255, correct index
sudo ./pctv_probe eeprom                    # the older sparse EEPROM dump
sudo ./pctv_probe romwin 300 /tmp/rw --no-fw --quiet
sudo ./pctv_probe eepromwin 600 /tmp/ew    # watch for the GET_EEPROM service
```

The index law, by hand (this is how it was measured — all 12 points agree):

```sh
# 8-byte window starting at EEPROM byte N  ->  wIndex = N << 8
sudo ./pctv_probe raw4 in 0x02 0x01a0 0x0000 8   # byte 0:   d0 04 23 2e 02 00 01 05
sudo ./pctv_probe raw4 in 0x02 0x01a0 0x0100 8   # byte 1:   04 23 2e 02 00 01 05 04
sudo ./pctv_probe raw4 in 0x02 0x01a0 0x1000 8   # byte 16:  69 6e 6e 61 63 6c 65 20
sudo ./pctv_probe raw4 in 0x02 0x01a0 0xff00 8   # byte 255: ff d0 04 23 2e 02 00 01 (wraps)
# wValue low byte = I2C address byte: 0x01a0 = read from 0xa0 (the EEPROM).
# 0x02a0/0x04a0/0x08a0/0x10a0 STALL, and so does 0x01a2 (the 24Cxx page bit) -
# so this request cannot address past byte 255 by itself.
```


### Why the window is missed so easily

* The bridge **re-enumerates** (device number changes) around resets; `romwin`
  re-opens by VID/PID every iteration, which is why it holds no long-lived state.
* `GET_VERSION` on recipient 0 and recipient 4 reach **different** code paths in
  the ROM — the tool tries both.
* A stall returns immediately (it is not a timeout), so the poll loop is fast;
  the firmware download is the slow part (~0.8 s).

---

## 8. Safety

* **Read-only to persistent storage.** No `SET_EEPROM`, no register writes.
* The RAM firmware download is non-persistent and proven unable to revive or
  damage the card.
* USB port reset (`--reset-every`) is the same operation `pctv_probe reset` has
  always done; it can drop the card off the bus, which §6 recovers.
* Interrupting with Ctrl-C leaves the card on the host and the module unloaded;
  nothing needs cleaning up.
