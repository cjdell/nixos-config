# fah-panel

Folding-heater telemetry web panel — ONE app for every space heater in the
fleet (hp-z240-xeon-1240v6-nixos: GTX 970 via the proprietary driver,
zen1-nixos: RX 5700 XT via amdgpu sysfs; more to come). Each heater differs
in what its GPU exposes, so the GPU half is pluggable behind one Sample
schema; the CPU half (k10temp/coretemp, cpufreq, RAPL) is cross-vendor sysfs
and shared. gpu-panel on zen3 is the overdrive-equipped sibling for AMD
compute GPUs — this crate is the heater dashboard.

Zero-dependency Rust (std only), frontend embedded via `include_str!` —
any frontend change requires rebuilding the binary.

## GPU backends (`--gpu auto|nvidia|amd`)

- **nvidia** — `--nvidia-smi <absolute store path>` (the panel never searches
  PATH, so the service pins the exact driver package). Polls
  `--query-gpu=util,memory,temp,fan,power,clocks,pstate,throttle`; the control
  is `nvidia-smi -pl` (NVML power cap, the one wattage knob GeForce has).
- **amd** — native amdgpu sysfs, resolved by `--amd-pci <vendor:device|BDF>`
  (empty = first PCI device exporting an amdgpu hwmon; prefer ids, BDFs
  shuffle): `gpu_busy_percent`, `mem_info_vram_*`, hwmon temps
  (`edge`/`junction`/`mem`), `power1_average`, `pwm1` → %, and the
  `pp_dpm_sclk`/`pp_dpm_mclk` tables for current+max clocks. The control is a
  write to `power1_cap` (microwatts); on Navi 10 it works with the *default*
  ppfeaturemask (verified on zen1), no overdrive bits needed. `power1_cap_*`
  supplies the slider range + hardware default live. amdgpu exposes no product
  name — pass `--gpu-name`.
- **auto** (default) — nvidia when `--nvidia-smi` is given, else amdgpu.

## Architecture

```
browser ──HTTP/SSE──> fah-panel ─┬─ nvidia: nvidia-smi --query-gpu / -pl
                                 └─ amd:    /sys/bus/pci/devices/*/{gpu_busy_percent,pp_dpm_*,hwmon}
                          └────> /sys: coretemp|k10temp hwmon, per-core cpufreq, RAPL package-0
```

- The **power cap is live state only**: whatever the backend reports is
  truth. Persisting a cap at boot is the job of a per-host unit (see
  `nvidia-power-limit.service` in
  `hosts/hp-z240-xeon-1240v6-nixos/folding-heater.nix`), not the panel.
- CPU columns are ported from gpu-panel: package temperature
  (`Tctl`/`Tdie`/`Package id 0`, hottest `Core` fallback), per-core
  `scaling_cur_freq` spread, package power differenced from the RAPL
  `energy_uj` counter (needs root — the service runs as root anyway for
  port 80 and both cap controls).
- The panel deliberately does **not** integrate the FAH client websocket
  API: folding progress lives in the FAH app (account token) and Web
  Control (`:7396`), the panel answers "is it brownouting" — GPU power vs
  cap, temps vs limits, clock throttles.
- **Rail voltages are not readable on these boards.** The Z240's HP
  Super-I/O hwmon exposes a single unwired `pwm1` (no VIN channels), there
  is no BMC/IPMI, and `nvidia-smi` has no sense lines. The honest software
  substitute is the **DC load estimate** card — CPU package power (RAPL) +
  GPU board power (NVML/amdgpu), the two loads that share the +12 V rail —
  with a `--budget W` line that turns amber/red as it approaches the margin
  that hard-resets that box. For real voltage traces: a multimeter, or an
  INA226-style inline USB monitor on the GPU adapter's 12 V feed.

## HTTP API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | dashboard (embedded HTML/JS/CSS) |
| GET | `/api/snapshot` | current sample + 600-sample history + control state + static cpu info |
| GET | `/api/stream` | SSE, one JSON sample per tick (2 s default) |
| GET | `/api/health` | liveness + backend/gpu/driver/cap-range info |
| POST | `/api/power` | `{"cap": 120}` — range-checked against the backend's cap min/max |
| POST | `/api/cpu-target` | `{"target": 75}` — CPU max-temperature slider; `0` = off |

`control` in the snapshot/health responses carries `backend` (`nvidia` /
`amd`), `gpu`, `driver`, `host`, `ram`, `cap`, `cap_min`/`cap_max`,
`cap_default` (0/absent → omitted by the UI), `budget`, and the CPU
auto-throttle state: `cpu_throttle` (a writable `scaling_max_freq` exists),
`cpu_target`, the applied `cpu_cap` (GHz, null = no limit) and its
`cpu_min_ghz`/`cpu_max_ghz` bounds.

## CPU max-temperature auto-throttle

The CPU sibling of the GPU cap slider: set a target temperature and the
sampler proportionally walks every cpufreq `scaling_max_freq` ceiling
(k10temp `Tctl` / coretemp `Package` as the sensor) — 12 MHz per °C of
error, clamped to ±40 MHz per 2 s tick and a ±0.5 °C deadband, between
`cpuinfo_min_freq` and `cpuinfo_max_freq`. Below the target the ceiling
drifts back up on its own. The slider itself is live state (a panel restart
releases the ceiling it set), so the STARTUP target is a host config value:
`services.fah-panel.cpuTempTarget` → `--cpu-target` on the ExecStart — that
is the one that persists across restarts and reboots (zen1 runs 80 °C;
the 1800X otherwise sits pinned at Tjmax folding). Like the GPU cap, the
kernel's own ~105 °C shutdown stays the last line of defence; this is about
keeping the chip and its neighbours cooler. (On acpi-cpufreq/AMD the kernel
clamps writes to `_PSS` entries — zen1's table tops out at 3.6 GHz, so the
panel reports the read-back ceiling, not its request.)

## Deployment

Built by `crates/fah-panel/nix/package.nix`, run as `fah-panel.service` by
`common/fah-panel.nix` (`services.fah-panel`), enabled per heater:

- `hosts/hp-z240-xeon-1240v6-nixos/folding-heater.nix` — `gpu = "nvidia"`,
  `budget = 180` → `http://192.168.49.65/`
- `hosts/zen1-nixos/folding-heater.nix` — `gpu = "amd"`, `amdPci =
  "1002:731f"` → `http://192.168.49.51/`

All heaters serve on **port 80** (next to the FAH Web Control on :7396), so
each box is just `http://<heater>/`. Adding the next heater = another host
module importing `common/fah-panel.nix`. (haswellatx's R9 290/390 is radeon,
not amdgpu — no `power1_average`, so it will want its own backend mode when
we get to it.)
