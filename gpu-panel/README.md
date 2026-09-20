# gpu-panel

Native GPU telemetry + overdrive control web panel for the R9700 on
zen3-nixos. Zero-dependency Rust (std only) — the frontend is embedded in the
binary via `include_str!`.

## Architecture

```
browser ──HTTP/SSE──> gpu-panel ──read──> /sys/bus/pci/devices/<bdf>/…
                          │                (temps, fan, power, clocks, util, VRAM)
                          ├──write───> gpu_od/fan_ctrl/*        (fan curve, fan limits)
                          ├──write───> hwmon/power1_cap         (power cap)
                          ├──write───> power_dpm_force_performance_level
                          └──write───> pp_od_clk_voltage         (clock/voltage offsets)
```

- **Everything is native sysfs**: monitoring *and* control. There is no daemon
  in the loop and no second writer, so a control set in the UI stays set —
  nothing else is holding an opinion about the fan, the cap or the clocks.
  `--state` (`/var/lib/gpu-panel/settings.json`) is the source of truth and is
  re-applied at startup.
- **The GPU is resolved by PCI BDF** (`--pci 0000:03:00.0`), not by DRM card
  number — those swap between boots.
- **The fan has exactly one writer**: the fan thread. It writes the PID curve
  while the thermal loop is armed, the configured curve while fan control is
  enabled, and hands the fan back to the firmware otherwise (including on
  SIGTERM/SIGINT), so a crash or restart cannot leave a stale curve behind.

## HTTP API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | dashboard (embedded HTML/JS/CSS) |
| GET | `/api/snapshot` | current sample + backfilled history + control state + thermal state |
| GET | `/api/stream` | SSE, one JSON sample per tick |
| GET | `/api/control` | control state (ranges + current values, read from sysfs) |
| GET | `/api/thermal` | PID controller state |
| GET | `/api/health` | liveness + sysfs reachability |
| POST | `/api/fan` | `{enabled, mode, static_speed, curve:[[t,s]…], minimum_pwm, target_temperature, acoustic_target, acoustic_limit}` |
| POST | `/api/power` | `{cap}` (null = firmware default) |
| POST | `/api/perf` | `{level: auto\|low\|high\|manual}` |
| POST | `/api/clocks` | `{gpu_clock_offset, voltage_offset, min_memory_clock, max_memory_clock}` or `{reset:true}` |
| POST | `/api/thermal` | `{action:"apply", target, source, kp, ki, kd, duty_min, interval_ms}` or `{action:"stop"}` |
| POST | `/api/reset` | everything back to firmware defaults, overrides cleared |

## Control interfaces

Exact forms, verified on this card (R9700, SMU 14, kernel 7.2). The offset
spellings differ per SMU generation, so they are **probed**: the unindexed
RDNA4 form is tried first and the indexed older form is the fallback.

| Knob | Path | Write |
| --- | --- | --- |
| fan curve | `gpu_od/fan_ctrl/fan_curve` | `"<i> <tempC> <speed%>"` ×5, then `c` (commit) / `r` (reset) |
| fan limits | `gpu_od/fan_ctrl/fan_minimum_pwm`, `fan_target_temperature`, `acoustic_{target,limit}_rpm_threshold`, `fan_zero_rpm_enable` | integer |
| power cap | `hwmon/power1_cap` | microwatts |
| perf level | `power_dpm_force_performance_level` | `auto`/`low`/`high`/`manual` |
| sclk offset | `pp_od_clk_voltage` | `s <mhz>` (RDNA4) or `s 1 <mhz>` |
| vddgfx offset | `pp_od_clk_voltage` | `vo <mv>` (RDNA4) or `vc 0 <mv>` |
| VRAM clocks | `pp_od_clk_voltage` | `m 0 <mhz>` / `m 1 <mhz>` |
| commit / reset | `pp_od_clk_voltage` | `c` / `r` |

The `gpu_od/fan_ctrl/*` files share the shape
`<HEADER>:\n<value>\nOD_RANGE:\n<KEY>: <min> <max>`, which is what
`read_od_block` parses for both the current value and the slider ranges.
Every write is **clamped to the advertised range first**: an out-of-range value
is rejected with `EINVAL`, and rejecting it partway through a multi-write
sequence (the OD table, or the fan limits) would leave the hardware and the
saved config disagreeing. A VRAM clock of 0 means "not configured" and leaves
the table's value alone, rather than clamping up to the minimum (which would
collapse the range to a single value).

### Clock/voltage safety

An overclock or undervolt that hangs the box must not be re-applied on the next
boot, or the host would never come up. So a clock/voltage write sets
`clocks_pending` in the state file, and only a **clean exit** clears it:

- startup with `clocks_pending` set means the last session went down without
  exiting, so the OD table is reset (`r`), the saved clocks are discarded and a
  warning is logged — the change is treated as the crash suspect;
- a normal stop/restart (SIGTERM, `nixos-rebuild switch`, reboot) confirms the
  change and drops the flag, so it is re-applied next boot.

Power cap, performance level and fan settings are deliberately excluded: they
cannot hang the machine, and they are re-applied unconditionally.

## PID thermal loop

Set a target (“max”) temperature; the loop adjusts fan duty to hold it.

- **Feedback source** is selectable: `edge`, `junction` (hotspot) or `mem`.
  **`junction` is the default and the only sensor the loop can truly
  regulate**: the SMU evaluates the overdrive curve against the hotspot, and
  under load the hotspot runs ~25–30 °C hotter than `edge` (and ~10 °C hotter
  than `mem`). Regulating `edge` means the loop sees “3 °C below target” and
  holds minimum duty while the junction climbs to 100 °C+.
- **Hotspot safety floor**: independently of the selected sensor the duty is
  max-selected against a ramp from `duty_min` at 90 °C to `duty_max` at
  100 °C, so a cool `edge`/`mem` reading can never starve the fan while the
  junction is near its limit. The guard can only add duty, never remove it.
- **Output**: a 5-point SMU overdrive curve, not a flat duty. The curve is
  centred at `target + (hotspot − source)` (the firmware evaluates the curve
  against the *hotspot* sensor) with `duty` at the centre, less below it, and
  a ramp to 100% above it. The two anchors above the centre are spread over
  the remaining range up to the 100 °C axis end so they cannot collapse onto
  each other. So the PID has authority near the setpoint while the firmware
  keeps a proportional response of its own — if this process dies with the fan
  low, the GPU still cools itself as temperature rises.
- **Gains**: `kp` (%/°C), `ki` (%/°C·s, clamped anti-windup), `kd` (%/°C/s,
  derivative on measurement). Defaults `4 / 0.4 / 1.5`. The integral term is
  capped at the output span, so a saturated loop unwinds in seconds.
- **Safety**: `measured ≥ 100 °C` **or `hotspot ≥ 100 °C`** forces full duty;
  `duty_min` defaults to the firmware's minimum PWM (~25%); a rising curve is
  always written, never a flat one.
- **Change detection**: the curve is only rewritten when a temperature anchor
  moves or a duty anchor moves ≥1%, so a settled loop stops touching the SMU.
- **Control handoff**: arming takes the fan from the configured curve; stopping
  (or SIGTERM/SIGINT) writes `r` to `fan_curve`, returning it to PMFW.
- Armed state + settings persist to `--state` (`/var/lib/gpu-panel/settings.json`)
  and are re-applied on restart. The saved file holds the *configuration* only
  (`enabled`, target, source, gains, `duty_min`/`duty_max`, `interval_ms`, plus
  the fan/power/perf/clock overrides); the runtime flags (`active`, integral,
  last curve) are rebuilt on load, and `active` is re-armed from `enabled` so an
  armed loop really resumes rather than sitting in the `enabled && !active`
  "starting…" state forever.

### Gotchas

- The overdrive curve is indexed by **hotspot** temperature, not edge — hence
  the centre offset above. Getting this wrong makes the fan run far from the
  commanded duty.
- Anchor writes are racy immediately after a commit: the code retries with a
  30 ms gap between anchors (`write_file_retry`).
- Minimum settable duty is the firmware `pwm_min` (~25%); lower values are
  rejected with `EIO`.
- A wrong command spelling on `pp_od_clk_voltage` is rejected with `EINVAL` —
  this is how the RDNA4-vs-older offset forms are probed.
- The panel runs as **root** — the overdrive sysfs writes require it.

## Deployment

`hosts/zen3-nixos/ai/gpu-panel.nix` builds the package, runs it as a systemd
unit on `127.0.0.1:8087`, and wires nginx (`/gpu/` on the IP vhost +
`gpu.ai.chrisdell.info`).

```sh
sudo nixos-rebuild switch --impure --flake . --max-jobs 1
sudo nixos-confirm
```
