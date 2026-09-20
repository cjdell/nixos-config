# gpu-panel

Native GPU telemetry + overdrive control web panel for the R9700 on
zen3-nixos. Zero-dependency Rust (std only) — the frontend is embedded in the
binary via `include_str!`.

## Architecture

```
browser ──HTTP/SSE──> gpu-panel ──read──> /sys/bus/pci/devices/<bdf>/…
                          │                (temps, fan, power, clocks, util, VRAM)
                          ├──write────> gpu_od/fan_ctrl/fan_curve   (PID loop only)
                          └──unix sock─> /run/lactd.sock             (LACT daemon)
```

- **Monitoring is native**: every sample is read straight from sysfs.
  The GPU is resolved by PCI BDF (`--pci 0000:03:00.0`), not by DRM card
  number — those swap between boots.
- **Control writes go through LACT** (`/run/lactd.sock`, newline-delimited
  JSON): power cap, clocks, voltage, performance level and the LACT fan
  curve/static modes. LACT owns the SMU plumbing and its unconfirmed-change
  auto-revert timer; gpu-panel sets a value and immediately confirms it, or
  explicitly reverts. This is deliberate — reimplementing overdrive safety
  here would be strictly more dangerous.
- **The PID thermal loop is the exception**: when armed, gpu-panel releases
  LACT's fan control and drives the SMU overdrive fan curve itself, because
  the loop runs at ~1 Hz and LACT persists a config file on every change.

## HTTP API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | dashboard (embedded HTML/JS/CSS) |
| GET | `/api/snapshot` | current sample + backfilled history + control state + thermal state |
| GET | `/api/stream` | SSE, one JSON sample per tick |
| GET | `/api/control` | LACT control state (ranges + current values) |
| GET | `/api/thermal` | PID controller state |
| GET | `/api/health` | liveness + LACT reachability |
| POST | `/api/fan` | `{enabled, mode, static_speed, curve:[[t,s]…], minimum_pwm, target_temperature, acoustic_target, acoustic_limit}` |
| POST | `/api/power` | `{cap}` (null = default) |
| POST | `/api/perf` | `{level: auto\|low\|high\|manual}` |
| POST | `/api/clocks` | `{gpu_clock_offset, voltage_offset, min_memory_clock, max_memory_clock}` or `{reset:true}` |
| POST | `/api/thermal` | `{action:"apply", target, source, kp, ki, kd, duty_min, interval_ms}` or `{action:"stop"}` |
| POST | `/api/confirm` · `/api/revert` | commit / undo LACT's pending change |

## PID thermal loop

Set a target (“max”) temperature; the loop adjusts fan duty to hold it.

- **Feedback source** is selectable: `edge`, `junction` (hotspot) or `mem`.
- **Output**: a 5-point SMU overdrive curve, not a flat duty. The curve is
  centred at `target + (hotspot − source)` (the firmware evaluates the curve
  against the *hotspot* sensor) with `duty` at the centre, less below it, and
  a ramp to 100% above it. So the PID has authority near the setpoint while
  the firmware keeps a proportional response of its own — if this process
  dies with the fan low, the GPU still cools itself as temperature rises.
- **Gains**: `kp` (%/°C), `ki` (%/°C·s, clamped anti-windup), `kd` (%/°C/s,
  derivative on measurement). Defaults `4 / 0.4 / 1.5`.
- **Safety**: `measured ≥ 100 °C` forces full duty; `duty_min` defaults to the
  firmware's minimum PWM (~25%); a rising curve is always written, never a
  flat one.
- **Change detection**: the curve is only rewritten when duty moves ≥1% or the
  centre ≥0.5 °C, so a settled loop stops touching the SMU.
- **Control handoff**: arming disables LACT fan control; stopping (or
  SIGTERM/SIGINT) writes `r` to `fan_curve`, returning the fan to PMFW.
- Armed state + settings persist to `--state` (`/var/lib/gpu-panel/thermal.json`)
  and are re-applied on restart.

### Gotchas

- The overdrive curve is indexed by **hotspot** temperature, not edge — hence
  the centre offset above. Getting this wrong makes the fan run far from the
  commanded duty.
- Anchor writes are racy immediately after a commit: the code retries with a
  30 ms gap between anchors (`write_file_retry`).
- Minimum settable duty is the firmware `pwm_min` (~25%); lower values are
  rejected with `EIO`.
- The panel runs as **root** — sysfs fan-curve writes and the LACT socket
  (root:wheel 0660) both require it.

## Deployment

`hosts/zen3-nixos/ai/gpu-panel.nix` builds the package, runs it as a systemd
unit on `127.0.0.1:8087`, and wires nginx (`/gpu/` on the IP vhost +
`gpu.ai.chrisdell.info`).

```sh
sudo nixos-rebuild switch --impure --flake . --max-jobs 1
sudo nixos-confirm
```
