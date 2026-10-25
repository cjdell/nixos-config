# fah-panel

Folding-heater telemetry web panel for the NVIDIA space heaters
(hp-z240-xeon-1240v6-nixos: GTX 970 via the proprietary driver — no hwmon,
no overdrive sysfs, so gpu-panel's sysfs model does not apply).

Zero-dependency Rust (std only), frontend embedded via `include_str!` —
any frontend change requires rebuilding the binary.

## Architecture

```
browser ──HTTP/SSE──> fah-panel ──poll──> nvidia-smi --query-gpu (util/power/temp/clocks/pstate/throttle)
                          │       └──> nvidia-smi -pl W (power cap, the one wattage knob GeForce has)
                          └────────> /sys: coretemp|k10temp hwmon, per-core cpufreq, RAPL package-0
```

- `nvidia-smi` is passed in as `--nvidia-smi <absolute store path>`; the
  panel never searches PATH, so the service pins the exact driver package.
- The **power cap is live state only**: whatever `power.limit` reports is
  truth. Persisting a cap at boot is the job of `nvidia-power-limit.service`
  (see `hosts/hp-z240-xeon-1240v6-nixos/folding-heater.nix`), not the panel.
- CPU columns are ported from gpu-panel: package temperature
  (`Tctl`/`Tdie`/`Package id 0`, hottest `Core` fallback), per-core
  `scaling_cur_freq` spread, package power differenced from the RAPL
  `energy_uj` counter (needs root — the service runs as root anyway for
  `nvidia-smi -pl`).
- The panel deliberately does **not** integrate the FAH client websocket
  API: folding progress lives in the FAH app (account token) and Web
  Control (`:7396`), the panel answers "is it brownouting" — GPU power vs
  cap, temps vs limits, clock throttles.
- **Rail voltages are not readable on this platform.** The Z240's HP
  Super-I/O hwmon exposes a single unwired `pwm1` (no VIN channels), there
  is no BMC/IPMI, and `nvidia-smi` has no sense lines. The honest software
  substitute is the **DC load estimate** card — CPU package power (RAPL) +
  GPU board power (NVML), the two loads that share the +12 V rail — with a
  `--budget W` line that turns amber/red as it approaches the margin that
  hard-resets this box. For real voltage traces: a multimeter, or an
  INA226-style inline USB monitor on the GPU adapter's 12 V feed.

## HTTP API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | dashboard (embedded HTML/JS/CSS) |
| GET | `/api/snapshot` | current sample + 600-sample history + control state + static cpu info |
| GET | `/api/stream` | SSE, one JSON sample per tick (2 s default) |
| GET | `/api/health` | liveness + gpu/driver/cap info |
| POST | `/api/power` | `{"cap": 120}` — range-checked against `power.min/max_limit` |

## Deployment

Built and run as `fah-panel.service` by
`hosts/hp-z240-xeon-1240v6-nixos/folding-heater.nix`, listening on
`0.0.0.0:7397` → `http://192.168.49.65:7397/`.
