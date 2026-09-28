# meter-relay-rs

A Rust port of [`meter-relay`](../meter-relay) with a live web dashboard instead
of console logging.

It lets a plant of solar inverters share a single grid power meter:

- Reads the grid meter over a serial Modbus RTU link and re-serves those
  registers over TCP to each inverter, so all of them still "see" a meter.
- Perturbs the meter's active-power register with a per-inverter PID nudge so
  the grid's active power is driven towards a small export target
  (`MR_METER_TARGET_POWER`).
- **Allocates by priority, not by ratio.** The plant is a list
  (`MR_INVERTERS`): the first inverter is the primary and is asked for the whole
  demand up to the authority it has been *observed* to deliver; each reserve
  after it is asked only for what the inverters before it cannot cover, and only
  after the loop has demonstrated it (the demand sits at the primary's limit
  while the grid is still off target, sustained past a wake delay). Release uses
  a wider margin, so the small battery is not cycled for load the main bank can
  carry.
- **Fills the same list in both directions.** PV surplus the main bank cannot
  absorb spills down the priority list, so the reserve is charged from surplus
  instead of being exported: it exists to cover demand the main bank cannot, and
  the peak-rate import it displaces is worth more than the export it forgoes.
  A reserve at its SOC ceiling is skipped, so this can never hoard an afternoon's
  export; `MR_<ID>_ABSORB_SURPLUS=false` makes any inverter discharge-only.
- During the cheap Octopus Go window it charges the batteries instead of
  load-balancing.
- Publishes sensor state to Home Assistant and writes control/meter telemetry to
  InfluxDB.
- Serves a **Solid.js + TypeScript dashboard** showing grid power/voltage, every
  inverter's power and the voltages it actually reports, the reserve's state and
  each inverter's learned authority, and the live state of every loop (setpoint,
  error, output, integral and performance metrics) over Server-Sent Events.

Adding hardware is a configuration change: a new inverter is another id in
`MR_INVERTERS` plus a `MR_<ID>_DRIVER`, and the allocator, control law,
telemetry, API and dashboard are all sized by that list. A genuinely new
*model* needs its register map added in two places (`driver_defaults()` in
`src/config.rs`, `inverters::build()` in `src/inverters.rs`); several inverters
may share one driver.

The control design — what was changed after the measurements in
[`CONTROL-REVIEW.md`](CONTROL-REVIEW.md), and why — is written up in
[`CONTROL-DESIGN.md`](CONTROL-DESIGN.md).

## Layout

| Rust                          | TypeScript equivalent        | Purpose                                            |
| ----------------------------- | ---------------------------- | -------------------------------------------------- |
| `src/parser.rs`               | `parser.ts`                  | Modbus RTU framing, CRC16, request/response types  |
| `src/transport.rs`            | `modbus-master.ts`/`-slave-group.ts` | Master (serve requests) and slave (poll) transports |
| `src/registers.rs`            | `modbus-slave-proxy.ts`      | Scheduled register polling + thread-safe cache      |
| `src/meter.rs`                | `meter.ts`                   | Grid meter register map and response rewriting      |
| `src/inverters.rs`            | `solis-inverter.ts`/`solax-inverter.ts` | Inverter register maps and typed getters  |
| `src/pid.rs`                  | `common.ts`                  | PID controller + performance metrics                |
| `src/allocation.rs`           | —                            | Priority split, learned authority, reserve policy   |
| `src/control.rs`              | `controller.ts`              | The control law (one tick) + simulated-plant tests  |
| `src/inverter_controller.rs`  | `common.ts`                  | Per-inverter PID nudge and register rewriting       |
| `src/controller.rs`           | `controller.ts`              | Wiring, connections, control loop, publishing       |
| `src/telemetry.rs`            | —                            | Shared live state + history + SSE broadcast         |
| `src/web.rs`                  | (Express `/stats`)           | HTTP API, SSE, and static dashboard                 |
| `src/home_assistant.rs`       | `home-assistant.ts`          | Home Assistant REST helpers                         |
| `src/influx.rs`               | (inline write clients)       | Batched InfluxDB line-protocol writer               |
| `web/`                        | —                            | Solid.js dashboard                                  |

## Endpoints

| Path           | Description                                            |
| -------------- | ------------------------------------------------------ |
| `/`            | Solid.js dashboard                                     |
| `/api/status`  | Full current telemetry snapshot (JSON)                 |
| `/api/history` | Bounded history of snapshots for the chart (JSON)      |
| `/api/events`  | Server-Sent Events stream of snapshots                 |
| `/stats`       | Legacy JSON endpoint, kept compatible with the TS service |

## Configuration

All settings come from `MR_`-prefixed environment variables. **Nothing on a
deployed host configures this binary**: on `grafton-router` the whole plant is
declared in `hosts/grafton-router/services/meter-relay.nix` and applied as
systemd `Environment`, and the four credential variables below are rendered into
an `EnvironmentFile` by sops. Changing behaviour means changing that Nix module
and rebuilding — see `CONTROL-DESIGN.md`.

Credentials (the only variables that are not plain Nix settings):

```
MR_HOME_ASSISTANT_API
MR_HOME_ASSISTANT_BEARER_TOKEN
MR_INFLUXDB_URL
MR_INFLUXDB_TOKEN
```

For local development a `.env` in the working directory is still read, and it
never clobbers variables already present in the environment — that is the only
remaining purpose of the file, and there is deliberately none on the host.

Optional overrides (defaults in parentheses): `MR_SERIAL_DEVICE`,
`MR_INVERTER_HOST` (`192.168.49.30`), `MR_STATS_PORT` (2002), `MR_WEB_PORT`
(8484), `MR_WEB_DIR` (`web/dist`), `MR_METER_TARGET_POWER` (50), `MR_PID_KP`
(0.9), `MR_PID_KI` (0.3), `MR_PID_KD` (0), `MR_CONTROL_DEADBAND` (20).

Plant-level reserve hysteresis: `MR_RESERVE_WAKE_ERROR` (120),
`MR_RESERVE_WAKE_DELAY_MS` (1500), `MR_RESERVE_RELEASE_MARGIN` (250),
`MR_RESERVE_RELEASE_DELAY_MS` (30000). The older `MR_SOLAX_WAKE_*` /
`MR_SOLAX_RELEASE_*` spellings are still read as fallbacks.

The plant itself is `MR_INVERTERS` (default `solis,solax`, in priority order),
and each entry takes `MR_<ID>_*` overrides — `<ID>` is the id uppercased, so the
existing `MR_SOLIS_*` / `MR_SOLAX_*` names keep working unchanged:

| Variable | Meaning |
| --- | --- |
| `MR_<ID>_DRIVER` | register map/driver to use (`solis`, `solax`); defaults to the id |
| `MR_<ID>_NAME` | display name for the dashboard |
| `MR_<ID>_PORT` / `_SLAVE` | meter-master port, and Modbus slave address on the stats socket |
| `MR_<ID>_KP` / `_KI` / `_KD` / `_NUDGE_LIMIT` / `_REVERSE` | this inverter's own nudge loop |
| `MR_<ID>_MAX_DISCHARGE` / `_MAX_CHARGE` | learned authority ceilings (W) |
| `MR_<ID>_SLEW` | how fast its target may move (W/s) |
| `MR_<ID>_CHARGE_POWER` | open-loop target in the Go window (W) |
| `MR_<ID>_MIN_SOC` / `_MAX_SOC` | don't discharge below / charge above this (%) |
| `MR_<ID>_ABSORB_SURPLUS` | may it take PV surplus the higher-priority inverters cannot? |
| `MR_<ID>_HA_PREFIX` | Home Assistant entity-id prefix (defaults per driver) |

The two-inverter defaults are 3600/3600 W and 4000 W/s for `solis` (port 2000,
slave 2, Kp 0.3, reversed), and 1500/1000 W and 1200 W/s for `solax` (port 2001,
slave 1, Kp 0.5, `MIN_SOC` 15, `MAX_SOC` 95). `MR_SOLAX_MAX_CHARGE` is 2000 in
the deployed configuration — the 1 kW code default left absorbable midday
surplus going to the grid. `CONTROL-DESIGN.md` says what each knob does.

## Running

This crate is part of the `nixos-config` repo and no longer has its own
`flake.nix`. The relay service's NixOS module
(`hosts/grafton-router/services/meter-relay.nix`) builds it by calling
`nix/package.nix` with this repo's nixpkgs and the `crane` flake input.

For development, use a Rust toolchain directly (`cargo run` reads `.env` if
present and serves the dashboard on `:8484`). To build the fully self-contained
binary the service uses (dashboard bundled and pointed at by a wrapper that sets
`MR_WEB_DIR`), run this from the repo root — `--no-link` keeps `nix build` from
dropping a `./result` symlink into the checkout, a stale one is worse than
useless because it points at whatever was built last, not at what is deployed:

```sh
nix build --no-link --impure --expr '
let
  f = builtins.getFlake (toString ./.);
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
in pkgs.callPackage ./crates/meter-relay-rs/nix/package.nix {
  craneLib = f.inputs.crane.mkLib pkgs;
}'
```

The Rust build is split with [crane](https://github.com/ipetkov/crane): the
crates.io dependency graph is compiled once and reused, so editing `src/`, the
dashboard, or the Nix files only recompiles this crate rather than all of its
dependencies.

Dashboard development with hot reload and API proxying to `:8484`:

```sh
cd web && npm install && npm run dev
```

## Checks

```sh
cargo test                 # parser, PID, allocator, control law vs a simulated
                           # plant, meter rewriting, web API
cargo clippy --all-targets -- -D warnings
cd web && npm run typecheck && npm run build
```
