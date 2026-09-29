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
- **Works out which serial connection is which at startup**, instead of trusting
  the port numbers: the three (soon four) USB adapters on the inverter-pi
  re-enumerate, so the relay listens for each inverter's own meter polls and
  probes the endpoints that stay silent. A second dashboard page
  (`/#/diagnostics`) shows what it decided, with each connection's last activity,
  health and error rate. See ["Which endpoint is
  which"](#which-endpoint-is-which-startup-auto-detection).

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
| `src/endpoint.rs`             | —                            | Where a Modbus conversation happens: `serial:` or `tcp://` |
| `src/discovery.rs`            | —                            | Startup auto-detection: listen, probe, decide which endpoint is which |
| `src/diagnostics.rs`          | —                            | Per-connection health, counters and error rates     |
| `src/telemetry.rs`            | —                            | Shared live state + history + SSE broadcast         |
| `src/web.rs`                  | (Express `/stats`)           | HTTP API, SSE, and static dashboard                 |
| `src/home_assistant.rs`       | `home-assistant.ts`          | Home Assistant REST helpers                         |
| `src/influx.rs`               | (inline write clients)       | Batched InfluxDB line-protocol writer               |
| `web/`                        | —                            | Solid.js dashboard (Live + Diagnostics pages)       |
| `scripts/capture-serial.py`   | —                            | Measure a meter line's request fingerprint          |

## Endpoints

| Path           | Description                                            |
| -------------- | ------------------------------------------------------ |
| `/`            | Solid.js dashboard. `/#/diagnostics` is the second page |
| `/api/status`  | Full current telemetry snapshot (JSON)                 |
| `/api/history` | Bounded history of snapshots for the chart (JSON)      |
| `/api/events`  | Server-Sent Events stream of snapshots                 |
| `/api/connections` | Which endpoint is which, plus per-connection health, counters and error rates (JSON, polled by the diagnostics page) |
| `/stats`       | Legacy JSON endpoint, kept compatible with the TS service |

## Which endpoint is which (startup auto-detection)

The remote adapters hang off a Raspberry Pi running `ser2net`, which bridges
three — soon four — **identical CH340 USB-serial adapters** onto TCP ports
(2000, 2001, 2002, 2003). The adapters carry no serial numbers, so Linux names
them `ttyUSB0`, `ttyUSB1`, … in probe order, and **the port-to-inverter mapping
is not stable across reboots**: the port that was the Solis meter line yesterday
can be the stats bus today. Because the Solis reads its meter *reversed*, a
silently swapped pair makes one inverter regulate the wrong way.

So the port numbers in the configuration are **hints, not truth**. At startup,
before anything is served or polled, the relay asks the wires:

1. **Listen** (read-only, in parallel, one window — 3 s by default) on every
   candidate endpoint. An inverter polling its grid meter is a Modbus *master*,
   so a meter-emulation line shows a stream of requests, and the registers it
   asks for are a fingerprint of the make/model. A line whose traffic matches a
   configured driver is that inverter's meter line.
2. **Probe** only the endpoints that stayed silent. The stats bus is silent
   until asked, so read each configured inverter's own power register at its
   slave address: whichever inverter answers identifies the bus. A local serial
   endpoint is asked for the grid meter's voltage register first and only falls
   through to the inverter probes if it does not answer.
3. **Retry** while anything required is still unplaced (an inverter may still be
   booting), then report.

Measured on the live plant (four endpoints, settled in 3.1 s, one attempt):

```text
tcp://192.168.49.30:2000: 3 meter polls: fc4 reg 0 n76 ×3 → solis (confidence 1.00)
tcp://192.168.49.30:2001: 11 meter polls: fc4 reg 12 n2 ×11 → solax (confidence 1.00)
tcp://192.168.49.30:2002: silent, then answered by solis (slave 2, 0 W), solax (slave 1, 2 W) → stats bus
serial:/dev/serial/by-id/usb-FTDI_USB_Serial_Converter_FTB6SPL3-if00-port0@9600: answered 240.7 V to the meter probe → grid meter
```

The same run with `MR_SOLIS_PORT=2001 MR_SOLAX_PORT=2000` (the ports configured
*backwards*, standing in for a shuffled reboot) identifies the same physical
lines and reports the mismatch rather than following the stale hints.

Two ordering details are deliberate. A line already carrying an inverter's own
polls is **never** probed — that would put two masters on one bus for no reason.
And a network endpoint is **never** classified as the grid meter, because an
inverter answers the meter's own registers too (they overlap its map); measured
on the live plant, a probe aimed at the Solax's power register on the USB meter
line got a perfectly valid reply *from the meter*.

| Variable | Meaning |
| --- | --- |
| `MR_DISCOVERY` | `auto` (default) or `off` — `off` trusts the configured ports exactly as the service did before discovery existed |
| `MR_DISCOVERY_STRICT` | Default `true`: refuse to start when a required connection cannot be identified. With `false`, an unverified line is served from its configured port and flagged on the diagnostics page |
| `MR_DISCOVERY_LISTEN_MS` | How long each silent endpoint is listened to (3000) |
| `MR_DISCOVERY_PROBE_MS` | How long a probe waits for a reply (250) |
| `MR_DISCOVERY_ATTEMPTS` | Identify-and-retry rounds (3) |
| `MR_CONNECT_TIMEOUT_MS` | How long opening an endpoint may take (3000) |
| `MR_ENDPOINTS` | Explicit candidate list, replacing the derived one: `192.168.49.30:2000-2003`, `tcp://host:port`, `/dev/ttyUSB2` |
| `MR_SERIAL_DEVICES` | Extra local serial candidates (the configured `MR_SERIAL_DEVICE` is always one) |
| `MR_SERIAL_BAUD` | Line speed for serial endpoints (9600) |
| `MR_<ID>_METER_POLL` | This inverter's meter-poll fingerprint, e.g. `4:0:76,4:342:2`, overriding the driver default |

**Strict mode is on by default on purpose.** An inverter answered with another
inverter's reverse setting is driven backwards, which is worse than not running
at all: the inverters raise their own metering fault and the old generation is
still on disk (`systemd` retries, and `nixos-confirm`/auto-rollback are
untouched).

### Adding an inverter

Append the id to `MR_INVERTERS`, give it `MR_<ID>_DRIVER` and `MR_<ID>_PORT`,
and its port becomes a discovery candidate automatically. Two cases:

- **Same model as one already configured** (a second Solax): its fingerprint is
  identical to the first, so listening cannot tell them apart. The configured
  ports break the tie, which is exactly what they are for. Note the same is true
  for the *stats* slave address — give the new inverter its own.
- **New model**: the relay has never seen its meter polls, so add them. With the
  service stopped (it holds those ports), measure them:

  ```sh
  sudo systemctl stop meter-relay
  nix shell nixpkgs#python3 --command \
    python3 crates/meter-relay-rs/scripts/capture-serial.py --port 2003 --seconds 60
  sudo systemctl start meter-relay
  ```

  The script prints the request patterns it saw and a ready-to-paste
  `MR_<ID>_METER_POLL="…"` line. Put that in the host's Nix, and (so every
  deployment knows the model) in `driver_meter_poll()` in `src/config.rs`.
  Capture it in **both** of the inverter's states if it has them: a Solax with
  no meter scans for one (`fc3 reg 11` at both candidate addresses) and only
  polls active power (`fc4 reg 12`, `fc4 reg 74`) once it has found one.

### Asking without starting

`MR_DISCOVERY_ONLY=1` runs the discovery phase, prints the table, and exits —
non-zero if a required connection could not be identified, so it can gate a
deploy script. It needs no credentials (it touches only the wires and reads
nothing else), and it never serves or controls anything:

```sh
MR_DISCOVERY_ONLY=1 MR_INVERTER_HOST=192.168.49.30 ./target/debug/meter-relay
```

Run it with the service stopped: `ser2net` is configured `kickolduser: true`, so
connecting to an endpoint displaces whoever holds it — a diagnostic run would
otherwise take the running service off its meter lines.

### Connections that drop

Every connection is supervised: it is dialled, and re-dialled with a backoff
(250 ms doubling to 10 s) whenever the link ends, so a `ser2net` idle timeout, an
inverter reboot or an adapter replug is repaired without a restart. The old
behaviour — the read loop ending and the service running on a dead socket
forever — is what the diagnostics page exists to make impossible to miss.

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
(0.9), `MR_PID_KI` (0.3), `MR_PID_KD` (0), `MR_CONTROL_DEADBAND` (20). The
endpoint-candidate and auto-detection variables are tabulated under
["Which endpoint is which"](#which-endpoint-is-which-startup-auto-detection).

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
| `MR_<ID>_METER_POLL` | the meter-poll requests this make/model sends, used by startup discovery (`4:0:76,4:342:2`) |

Note that `MR_<ID>_PORT` is a *hint*: the port the relay actually serves this
inverter's meter line on is whatever discovery finds, and the two differ exactly
when the adapters have re-enumerated. The configured value still decides which
endpoint to fall back to, and breaks the tie between two inverters of the same
model — see ["Which endpoint is
which"](#which-endpoint-is-which-startup-auto-detection).

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
                           # plant, meter rewriting, transport reconnection,
                           # endpoint parsing, discovery decisions, web API
cargo clippy --all-targets -- -D warnings
cd web && npm run typecheck && npm run build
```

The discovery rules are unit-tested against the real plant's fingerprints — the
usual layout, the shuffled one, a stale hint, a silently swapped pair, two
identical inverters, a spare port — so a change to the scoring shows up as a
failing test rather than as a swapped inverter at dusk. Verifying the *wiring*
itself needs the hardware: `MR_DISCOVERY_ONLY=1` (above) or the diagnostics page
at `/#/diagnostics`.
