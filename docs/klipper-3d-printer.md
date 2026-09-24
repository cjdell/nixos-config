# 3d-printer-server / Klipper (Smoothieboard LPC1768) — runbook & findings (2026-09-24)

**Status: two problems fixed, one STILL OPEN.**
Fixed: the `podman-klipper` boot race (§3) and the 16-month MCU-firmware version
drift (§4). Open: the thermistor/ADC readings are implausible (§6) — that section
is written so it can be picked up cold.

---

## 1. The machine

| | |
| --- | --- |
| Host | **`3d-printer-server`** = `192.168.49.60` (static lease in `hosts/grafton-router/networking/dns.nix`) |
| Hardware | Dell OptiPlex 4770, i7-4770, 8 cores |
| Config | `machines/dell-optiplex-core-4770/` (flake host attr `3d-printer-server`) |
| autoRollback | **not enabled here** → no `nixos-confirm` needed after rebuilds |
| Board | **Smoothieboard, LPC1768** @ 100 MHz, USB CDC-ACM, 16 KiB Smoothieware/DFU bootloader |
| Serial | `/dev/serial/by-id/usb-Klipper_lpc1768_0D40001727953EAE6BC5B753C52000F5-if00` → `ttyACM0` |

Stack: three rootful podman containers, one systemd unit each —
`podman-klipper.service`, `podman-moonraker.service`, `podman-mainsail.service`.
Mainsail is served by the host's nginx on :80, so `http://192.168.49.60/` is the UI.
(`podman-fah.service` is failed/pre-existing, unrelated.)

Printer project checkout: `/home/cjdell/Projects/prind.delta` (a `mkuf/prind` fork).
Container mounts:

- `config/` → `/opt/printer_data/config` (holds `printer.cfg`)
- podman volume `prinddelta_log` → `klippy.log`, `moonraker.log`
- podman volume `prinddelta_run` → `klipper.sock`, `klipper.tty`

`printer.cfg` pins that matter:

```ini
[extruder]
heater_pin: P2.7
sensor_type: ATC Semitec 104GT-2
# sensor_pin: P0.23          <- spare ADC pin, already there as an alternative
sensor_pin: P0.25            # ADC0.2

[heater_bed]
heater_pin: P2.5
sensor_type: Honeywell 100K 135-104LAG-J01
# sensor_pin: P0.24          <- spare ADC pin
sensor_pin: P0.26            # ADC0.3
```

Both sensors use Klipper's default `pullup_resistor` of 4700 Ω. Bed limits are the
defaults `min_temp: 0 / max_temp: 130`.

## 2. Deploying config changes to this host

This host has **no GitHub credentials** (`git pull` → `Permission denied (publickey)`),
so commits travel as a git bundle:

```sh
# where the commit lives
git push origin main
git bundle create /tmp/nc.bundle <sha-currently-on-host>..main
scp /tmp/nc.bundle cjdell@192.168.49.60:/tmp/
ssh cjdell@192.168.49.60 'cd ~/nixos-config && git pull --ff-only /tmp/nc.bundle main'
```

Then rebuild **as root via nohup**, and poll it:

```sh
ssh cjdell@192.168.49.60 'cd ~/nixos-config && nohup sudo nixos-rebuild switch --flake . >/tmp/rebuild.log 2>&1 &'
```

**Gotcha:** `systemd-run --unit=… nixos-rebuild …` fails with
`error: opening Git repository "…": repository path '…' is not owned by current
user (libgit2)` — root has no gitconfig/`safe.directory` and the transient unit
lacks the login environment. `nohup sudo …` from a login shell works.
Add `--max-jobs 1` to keep the build light on this box.

## 3. FIXED — klipper container lost a boot race (every boot, ≥10 days)

**Symptom:** after a boot there is **no `klipper` container at all**
(`sudo podman ps -a` shows only `mainsail` and `moonraker`), so Moonraker has no
printer and Mainsail has nothing to show.

**Cause:** the OCI module's generated unit was ordered only after
`network-online.target`. The MCU is a USB CDC-ACM device that enumerates **~20 s
into boot** — after the container units start — so the container aborted with:

```
Error: stat /dev/ttyACM0: no such file or directory
```

and because the module sets `Restart=on-failure` with `RestartSec=100ms`, it burned
systemd's default `StartLimitBurst=5` / `StartLimitIntervalSec=10s` and latched into
`start-limit-hit` for the rest of the boot. Seen at least 10× in 10 days.

**Fix** (`machines/dell-optiplex-core-4770/3d.nix`):

```nix
systemd.services."podman-klipper" = {
  wants = [ "dev-ttyACM0.device" ];
  after = [ "dev-ttyACM0.device" ];
  unitConfig = { StartLimitIntervalSec = 300; StartLimitBurst = 30; };
  serviceConfig.RestartSec = 5;
};
```

Verified live: `After=… dev-ttyACM0.device`, `StartLimitIntervalUSec=5min`, and the
unit survived an activation restart — the exact case that used to fail.

Recovery without a rebuild: `sudo systemctl reset-failed podman-klipper && sudo systemctl start podman-klipper`.

## 4. MCU firmware updates — `klipper-firmware-update`

**Why it exists.** The klipper container tracks the floating **`latest`** tag (the
upstream README is explicit that it may move within 24 h) and podman re-pulls it on
every container start. So host-side Klipper changes **silently**, while the firmware
actually flashed into the MCU only changes when someone does it by hand. On
2026-09-24 the host was `v0.13.0-770-gce7002bed` while the MCU still ran a build
from **2025-05-25** — ~16 months of drift.

Installed by `machines/dell-optiplex-core-4770/klipper-firmware.nix`
(`writeShellApplication`, so podman/jq/curl stay on `PATH` under `sudo`); the script
source is `klipper-firmware-update.sh` beside it. It derives the target version from
the image label `org.prind.image.version`, so host and MCU can no longer drift.

```sh
sudo klipper-firmware-update --status                          # image / host / MCU versions
sudo klipper-firmware-update                                   # build only
sudo klipper-firmware-update --to-sd /run/media/$USER/<card>    # build + write firmware.bin
sudo klipper-firmware-update --flash                           # build + flash over USB DFU
```

Build: `make olddefconfig && make -j$(nproc)` inside
`mkuf/klipper:<version>-tools`, with the host bind-mounting
`config/build.smoothieboard.config` → `/opt/klipper/.config` and
`out-smoothieboard/` → `/opt/klipper/out`. The seed config pins only the board
selection; `olddefconfig` fills the rest, yielding `CONFIG_MCU="lpc1768"`,
`CONFIG_LPC_USB=y`, `CONFIG_FLASH_APPLICATION_ADDRESS=0x4000` (16 KiB bootloader),
`ADC_MAX=4095`, `CLOCK_FREQ=100000000`.

**Traps learned the hard way:**

- **Do not use `config/build.config`.** It is a stale **RP2040** config left over
  from an unrelated build (`out/board → src/rp2040`) and would produce firmware for
  the wrong MCU.
- **Never `make clean`.** It runs `rm -rf $(OUT)` and `$(OUT)` is a bind-mount point:
  `rm: cannot remove 'out/': Device or resource busy`. The script wipes the output
  dir host-side before starting the container instead.
- **Builds are not byte-reproducible.** The image embeds its own build stamp; two
  clean builds differ in exactly **19 contiguous bytes** (offset 39703–39721 of
  42436) and nothing else. Don't compare hashes across builds — compare the *card
  copy* against the build you just made.
- `--flash` needs `dfu-util` (device id `1d50:6015`) and the board in bootloader
  mode: **hold PLAY, press+release RESET, release PLAY**.

### SD-card flash procedure (the method this board uses)

1. Insert the card into the host and identify it — **never by path guess**:
   `lsblk -o NAME,SIZE,RM,TRAN,MOUNTPOINT`. Expect a `RM=1, TRAN=usb` device
   labelled **`Smoothie`** (`/dev/sdb1`). **`sda` is the internal SATA system disk.**
2. Mount it rw, `sudo klipper-firmware-update --to-sd <mountpoint>`, `sync`, `umount`.
3. Move the card to the Smoothieboard and power-cycle. The bootloader flashes
   `firmware.bin` and renames it `FIRMWARE.CUR` (a `FIRMWARE.CUR` dated
   2025-05-25 is the proof this is the method used last time).
4. `sudo klipper-firmware-update --status` to confirm; issue `FIRMWARE_RESTART`
   if Klipper doesn't reconnect on its own.

The previous firmware is saved before overwriting: on the card under
`Backup-Firmware/`, and on the host at `~/klipper-firmware-backups/`.

MCU version strings read `<version>-<build-datetime UTC>-<12 hex>`:

```
before:  ?-20250525_151457-8fa542eb1701
after:   v0.13.0-770-gce7002bed-prind-20260924_152922-ecb87f210da6   # 16:29 BST = 15:29:22 UTC
```

(The `?` is where the tag couldn't be determined at build time. Note the datetime is
**UTC** — handy for cross-checking which build actually landed.)

## 5. Troubleshooting: "Mainsail does not load"

**Mainsail's own files are usually not the problem.** Check in this order:

```sh
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.49.60/     # 200 = nginx + mainsail fine
curl -s http://192.168.49.60/printer/info                          # klippy state
sudo podman logs --since 5m moonraker | grep -c pending            # >0 = klippy not answering
```

Mainsail's SPA never finishes loading when Moonraker can't get answers out of klippy.
In this session the trigger was an **MCU-side shutdown** (§6) that left klippy
*wedged*: its API socket **accepted connections but never replied** — reproducible
independently of Moonraker:

```sh
sudo curl -v --max-time 10 \
  --unix-socket /var/lib/containers/storage/volumes/prinddelta_run/_data/klipper.sock \
  http://localhost/printer/info      # hangs forever: request sent, 0 bytes received
```

so Moonraker logged `Request 'info' pending: 60.00 seconds` indefinitely.

**Recovery:**

```sh
sudo systemctl restart podman-klipper.service podman-moonraker.service
curl -X POST "http://127.0.0.1/printer/gcode/script?script=FIRMWARE_RESTART"
```

Then confirm `state: "ready"` and that the `pending` count is 0.

## 6. OPEN — thermistor readings implausible (bed ≈ 86 °C, extruder ≈ 81 °C, frozen)

**Symptom.** Both temperatures read a stable but wrong value that does not change
when heating is switched on. Onset was mid-print: job 57
(`Pencil_Organizer…`) died 13:06:54 BST with `klippy_shutdown` after ~27 min.

**Established by measurement:**

| | |
| --- | --- |
| Reported | bed 85.96–86.08 °C, extruder 81.02–81.10 °C; they drift together, no cooling trend when idle |
| Raw ADC (`QUERY_ADC`) | extruder `0.688889`, bed `0.688919` → **2821 / 2821.12 counts** — agreeing to 0.12 of one LSB (0.004 %) |
| Implied node resistance | 4700 × 0.6889/0.3111 = **10.41 kΩ on both channels** |
| Expected for a 100 k thermistor | 0.955 → 3911 counts |
| Thermistors themselves | measured by owner (unplugged) at **~100 kΩ each — good** |
| After the firmware reflash | **unchanged** (still 81/86) — as predicted, see below |

The reflash prediction held because `src/lpc176x/adc.c` and
`klippy/extras/adc_temperature.py` are **byte-identical** between `v0.13.0-745`
(the host version running on 2026-08-28 → 09-24, while this worked) and the current
`v0.13.0-770`. The host update never touched the temperature path.

**Ruled out, with the arithmetic:**

- *Two independent input faults:* they would have to agree to 4 parts in 10⁵. Because
  the two networks are nominally identical (4.7 k + 100 k), a **shared** cause
  reproduces that equality naturally; two coincidental faults do not.
- *Sensor lines shorted to each other:* with both pullups (2.35 k) and both
  thermistors (50 k) that node reads **0.816**, not 0.689.
- *A fixed leakage to ground (~11.7 k):* reproduces the 0.689 **value**, but predicts
  heating would swing the reading to ~0.535 — a huge, obvious change.
- *A dead / damaged / non-sampling ADC:* **excluded.** The readings do track input
  impedance. During the shutdown episode the raw values ramped
  `2826 → 3076 → 3488 → 3885 → 4094` (full scale) and the MCU shut down — full scale
  is exactly what an **open** input does (sample-and-hold charging to VREF), which is
  consistent with the thermistors being unplugged for measurement at that moment.
- *Host-side software:* code path identical across the working and current versions.

**Leading hypothesis (NOT yet confirmed):** the analog rail feeding the thermistor
pullups sits at **~2.4 V** while the ADC is still referenced to 3.3 V. Then both
channels report `2.38/3.3 × 0.955 = 0.689` — precisely the observed value, and
identical on both because the networks are identical. The LPC1768 runs happily down
to 2.4 V, so nothing else on the board would look wrong. This would *also* weaken the
heater MOSFETs' gate drive, which would explain "no visible change when I turn the
heating elements on" — i.e. they may not be heating at all.

**Tests to run, in order of information per minute:**

1. **DMM the board's 3.3 V rail.** 3.3 V or ~2.4 V? Single most informative measurement.
2. **DMM a thermistor signal pin to GND** with everything connected: **~2.27 V
   confirms the hypothesis**; ~3.15 V means the node is fine and the ADC/reference is
   lying instead.
3. **Do the bed and hotend actually get warm?** (touch test). If not, that is
   independent support for the shared-rail theory — and it invalidates any
   "no response to heating" observation, since nothing was heating.
4. **Pin-swap test (no DMM needed, config already supports it):** move both thermistor
   plugs to the TH1/TH2 headers and uncomment `# sensor_pin: P0.23` / `P0.24` in
   `printer.cfg`, then restart. Plausible temps → the `P0.25`/`P0.26` pins or their
   board network are at fault. Still 0.689 on the new pins → the ADC block/reference
   itself is dead → board replacement.

> ⚠️ **Safety while this is unresolved.** Do not leave a heater running. With a
> reading that is wrong but *in range*, Klipper will hold the heater at 100 % duty and
> `max_temp` cannot trip — only `verify_heater` will stop it, and only after the heater
> has been at full power for its whole check window. Judge heating by watching the
> machine / a meter, not by trusting the UI.

The MCU is also shutting down because of this: the range check trips when a sample
lands out of range. Those events are logged as:

```
MCU 'mcu' shutdown: ADC out of range
Sensor 'heater_bed' temperature -90.724 not in range 0.000:130.000
```

Each such shutdown wedges klippy → Mainsail stops loading (§5).

## 7. Diagnostic recipes worth reusing

**Raw ADC values** — no hardware access needed. `QUERY_ADC` is registered by
`klippy/extras/query_adc.py`; its output goes to the console *and* into `klippy.log`:

```sh
curl -s -X POST -G --data-urlencode 'script=QUERY_ADC NAME=heater_bed PULLUP=4700' \
  http://127.0.0.1/printer/gcode/script
sudo grep -a "has value" \
  /var/lib/containers/storage/volumes/prinddelta_log/_data/klippy.log | tail
```

`PULLUP=4700` makes it print the implied resistance directly. Registered ADC objects
here: `"extruder"`, `"heater_bed"`.

**MCU shutdowns and the host's clarification:**

```sh
sudo grep -aE "^MCU .*shutdown|not in range" …/klippy.log | tail
```

**The log is spammy.** Two filters do most of the work — `grep -v "^Stats"` and
`grep -v ": got {"` (the latter are per-message `analog_in_state` debug dumps; they
are how the raw ADC ramp in §6 was caught).

**`Stats` lines are a health check** — `freq=99999325` (healthy 100 MHz clock),
advancing `send_seq`/`receive_seq` (link alive), plus both temps.

**Version drift:** `sudo klipper-firmware-update --status`.

**Is klippy wedged?** Connect to its socket directly; a *hang* (not a refusal) means
the API is wedged, per §5.

## 8. Timeline (2026-09-24)

| Time (BST) | Event |
| --- | --- |
| 12:31 | host reboot; podman re-pulled `mkuf/klipper:latest` → host silently became `v0.13.0-770` |
| 13:06:54 | print job 57 dies — `klippy_shutdown` |
| 15:56 | boot: `podman-klipper` loses the boot race (`start-limit-hit`); temps already implausible |
| 15:58 | container started by hand |
| 16:16 | `nixos-rebuild switch` — boot-race fix + firmware tool deployed; klipper container recreated |
| ~16:20–16:32 | thermistors unplugged for measuring (→ open inputs); printer power-cycled for the flash |
| ~16:37 | MCU shuts down `ADC out of range` (bed −90.7 °C) → klippy wedge → Mainsail stuck |
| 16:47 | klipper + moonraker restarted, `FIRMWARE_RESTART` → `ready`; temps still 81/86 |
