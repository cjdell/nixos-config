> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## meter-relay-rs (grafton-router, live)

The solar-inverter meter relay on **grafton-router** (the router itself,
`192.168.49.1`) is built from the Rust crate at `crates/meter-relay-rs` in this
repo — *not* the older TypeScript app in `/home/cjdell/Projects/meter-relay`
(kept for reference only), and no longer from the external checkout at
`/home/cjdell/Projects/meter-relay-rs` (the crate was folded into this repo;
the old checkout is just a backup). The
live `MR_*` credentials used to live in a `.env` in the old Rust checkout; they
are
in sops now and there is no `.env` on the host. It reads the grid meter
over serial Modbus RTU, re-serves those registers to the inverters, nudges them
with per-inverter PIDs so grid export tracks `MR_METER_TARGET_POWER`, charges the
batteries in the Octopus Go window, publishes to Home Assistant + InfluxDB, and
serves a Solid.js dashboard on `:8484` (`/api/status`, `/api/history`,
`/api/events` SSE, `/api/connections`, legacy `/stats`) with a second
`/#/diagnostics` page.

- **The endpoint→role mapping is discovered at startup, because the ports are
  not stable.** The inverter-pi (`192.168.49.30`, `ser2net`) bridges three (soon
  four) *identical* CH340 USB adapters with no serial numbers onto TCP
  2000/2001/2002/2003, so `/dev/ttyUSBn` — and therefore which inverter hangs off
  which port — re-enumerates across reboots. `MR_*_PORT`/`MR_STATS_PORT` are
  **hints**; at startup `src/discovery.rs` *listens* (read-only, 3 s, in
  parallel) for each inverter's own meter polls and *probes* only the endpoints
  that stayed silent (the stats bus and the local USB grid meter answer; a line
  with an inverter polling on it is never probed, and a TCP endpoint is never
  classified as the grid meter because an inverter answers the meter's own
  registers too). `MR_DISCOVERY_STRICT=true` (the deployed setting) refuses to
  start when a required connection cannot be placed — an inverter answered with
  another inverter's `MR_<ID>_REVERSE` is driven *backwards* — and
  `MR_DISCOVERY=off` restores the old trust-the-port behaviour.
- **`MR_DISCOVERY_ONLY=1` asks what the wiring looks like without starting the
  service**: it needs no credentials, prints the table, and exits non-zero if a
  required connection is unidentified. Stop `meter-relay` first — `ser2net` is
  `kickolduser: true`, so connecting displaces whatever holds the port.
- **The grid meter's identity is a probe answer, not a path** (since 2026-11-27,
  the day the FT232R carrying it *died on the USB bus fourteen seconds after
  discovery had confirmed it as the meter*). Its relay — whose only candidate
  was the one configured by-id path — re-dialled the dead name for nine hours
  while the plant ran on a frozen meter reading. Two changes came out of that:
  discovery is now offered **every port the kernel lists** (`/dev/serial/by-id`,
  `/dev/serial/by-path`, deduplicated by resolved device — `src/serial.rs`,
  `MR_SERIAL_AUTO`/`MR_SERIAL_DIRS`), so a meter re-plugged into a different
  adapter is found there at the next startup; and if the meter's node is absent
  from the bus for `MR_METER_GONE_AFTER_MS` (default 60 s) while its lane is
  down, the process **exits** with a clear journal line and the systemd restart
  re-runs full startup discovery — the one thing that can re-place the meter,
  since discovery is what chose the endpoint. `MR_SERIAL_EXCLUDE` is
  load-bearing: on grafton-router it names `/dev/otbr-rcp`, because opening the
  Thread border router's radio mid-frame while otbr-agent reads it would break
  the mesh quietly. It matches the *device the link resolves to*, so it follows
  radio swaps and can never veto an adapter that might one day carry the meter.
- **A stale measurement is never served as if it were fresh** (2026-11-27): every
  meter register carries a freshness window — three polls of the most-often-polled
  definition covering it, floored at 5 s (`meter.rs::stale_window_ms`) — and when it
  lapses the *flow* registers (active power and current) **read 0** everywhere the
  plant consumes them: dashboard, Home Assistant, the emulated meter line. The
  rest of the meter deliberately keeps its last believable value: an energy
  **counter** reset to zero in front of an inverter is a worse lie than a slow
  one, and a meter reading 0 VA / 0.00 V while the PID nudges non-zero watts is a
  physically impossible device. That last case is not theoretical — the first
  cut of this policy zeroed too much, three relay restarts in five minutes let a
  Solis cross-check its meter, and **fault 8217 `Meter Select Fail` latched**
  (with the inverter then refusing to act and the relay-side authority estimates
  collapsing to their floors — the 2026-09-26 pattern, from the other side). The
  emulated line also never starts cold: a never-measured voltage is served as a
  believable 230 V (`DEFAULT_GRID_VOLTAGE`), because the inverters poll the meter
  within ~2 s of a relay restart and "45 W at 0.00 V" must never be a thing this
  relay says. The central loop meanwhile **holds** (`ControlLaw::hold()`): feeding
  the made-up 0 W to the PID would chase a grid flow nobody measured, and the
  per-inverter loops keep nudging at the held targets with *live* battery
  readings, so the plant stays put instead of steering by the frozen number —
  which is precisely what the nine hours of 2026-11-27 were doing. `/api/status`
  carries `meter_stale: true`, and the dashboard wears a red
  `meter stale · holding` chip.
- **It shouts when the plant should not be trusted** (`src/alerts.rs`): a 5 s
  watchdog assembles the problems (stale meter feed, links not online-and-healthy),
  debounces them through `MR_ALERT_GRACE_MS` (60 s — reconnect backoff must never
  page), fires every `notify.*` service listed in `MR_ALERT_HA_SERVICES` — new
  problems, cleared problems, and the whole list again every `MR_ALERT_REPEAT_MS`
  (30 min) while anything stays active — mirrors `sensor.meter_relay_alerts`
  (`"ok"` or the problem list) for automations, and `MR_ALERT_WEBHOOK_URL` (unset)
  can add any generic `{"title","message"}` JSON webhook (ntfy, an HA webhook).
  A relay that cannot start — startup discovery refusing exactly when the meter
  answers nowhere — cannot shout for itself, so the `meter-relay-alert.service`
  `OnFailure=` unit does: one push per ten minutes at most (a strict-mode
  crash-loop exits every ~15 s), and it leaves an outage marker in the shared
  StateDirectory so the first clean run after an outage pushes RECOVERED instead
  of silence. Test it live: `sudo kill -9 $(pidof meter-relay)` — OnFailure fires
  only on failure, not on `systemctl stop`.
- **Every connection reconnects on its own** (250 ms backoff doubling to 10 s).
  A dropped link used to leave the service running on a dead socket forever,
  which is what `/api/connections` and the diagnostics page exist to make
  visible: per connection, the discovered identity (and `mismatch` when it
  disagrees with the configured hint), state, last rx/tx, frame and directional
  counters, timeouts/CRC/exception/IO errors, reconnects and a windowed error
  rate. `src/diagnostics.rs` owns those counters; nothing there is on the control
  path.
- **A new inverter of an already-known model** works from `MR_<ID>_DRIVER` +
  `MR_<ID>_PORT` alone (its port is a candidate automatically; identical
  fingerprints are told apart by the configured port, which is what the hint is
  for). **A new model** also needs its meter-poll fingerprint —
  `MR_<ID>_METER_POLL="4:0:76,4:342:2"`, and a row in `driver_meter_poll()`
  (`src/config.rs`) — measured on the live line with
  `crates/meter-relay-rs/scripts/capture-serial.py`. Capture both of an
  inverter's states if it has them: a Solax with no meter scans for one
  (`fc3 reg 11` at both candidate addresses) and only polls active power
  (`fc4 reg 12`, `fc4 reg 74`) once it has found a meter. A model with no
  fingerprint at all cannot be placed, and strict mode will refuse to start.
- **The plant is a priority list, not two hardcoded inverters.** `MR_INVERTERS`
  orders it (default `solis,solax`) and each entry takes `MR_<ID>_*` overrides,
  so the existing `MR_SOLIS_*`/`MR_SOLAX_*` names still work. Entry 0 is the
  primary actuator; the rest are the reserve. Adding a third inverter is another
  id in the module's `plant` attrset plus `MR_<ID>_DRIVER` pointing at a known
  driver; a genuinely new *model* needs a row in
  `driver_defaults()` (`src/config.rs`) and an arm in
  `inverters::build()` (`src/inverters.rs`). Duplicate ports or slave addresses
  are a startup error.
- **Allocation water-fills in both directions**, so surplus PV the main bank's
  charge taper cannot absorb spills into the reserve instead of being exported
  (it exists to cover demand the main bank cannot, and the peak-rate import it
  displaces beats the 12p export). A reserve at `MR_<ID>_MAX_SOC` is skipped;
  `MR_<ID>_ABSORB_SURPLUS=false` makes an inverter discharge-only. `/api/status`
  now publishes `inverters: [...]` rather than named `solis`/`solax` keys —
  `/stats` and the Home Assistant entity ids are unchanged.

- Module: `hosts/grafton-router/services/meter-relay.nix` (imported by
  `services/default.nix`). **It is the relay's entire configuration** — the
  plant is declared there as an attrset applied via systemd `Environment`, so
  behaviour changes are Nix changes (`nixos-rebuild switch`), not edits on the
  host. The two credentials come from sops through
  `sops.templates."meter-relay.env"` + `EnvironmentFile`: the Home Assistant
  token reuses the existing `home_assistant_token` secret (byte-identical to
  what the old `.env` held), and `meter_relay_influxdb_token` is the relay's own.
  There is deliberately **no `WorkingDirectory` and no `.env`** on the host —
  the process CWD is `/`, so a stray `.env` has nowhere to be picked up from
  (dotenvy survives only as a local-development convenience). The dashboard is
  bundled into the store by the crate's own `nix/package.nix`
  (`buildNpmPackage` + a wrapper exporting `MR_WEB_DIR`) — a frontend change
  needs a rebuild, never a file copy.
- To change one setting, edit the `plant` attrset in that module. Non-secret
  values are visible in `systemctl show meter-relay -p Environment`; the tokens
  are not (they arrive via the rendered `/run/secrets/rendered/meter-relay.env`,
  mode 0400 root).
- **Build:** the crate lives in this repo at `crates/meter-relay-rs`. The root
  flake builds it — `hosts/grafton-router/services/meter-relay.nix` calls its
  `nix/package.nix` via `pkgs.callPackage` with
  `craneLib = inputs.crane.mkLib pkgs` (crane is a `flake.nix` input, no nixpkgs
  follow). There is **no separate `meter-relay-rs` input or `flake.lock` entry
  any more**, so a plain `nixos-rebuild switch --flake .` always builds the
  working tree. Live logs: `journalctl -u meter-relay -f`.
- **No Rust toolchain on grafton-router** (no `cargo`, no `rustc`, no `cc`), so
  the crate cannot be built with a bare `cargo test`. One command supplies
  everything for a fast edit/test loop — `cc` is needed to link build scripts and
  the `udev.dev` output for `tokio-serial`'s `libudev`:

  ```sh
  nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#pkg-config nixpkgs#stdenv.cc \
    nixpkgs#udev.dev nixpkgs#clippy --command bash -c \
    'cd crates/meter-relay-rs && cargo test && cargo clippy --all-targets -- -D warnings'
  ```

  `web/` needs `npm install` once (network); `npm run typecheck && npm run build`
  then work offline.

### Deploying a change (the step that gets missed)

`scripts/deploy-meter-relay.sh` does all of the below and verifies the result
(`--no-rebuild` evaluates and reports only; it refuses to switch on any host but
grafton-router). By hand:

```sh
cd ~/nixos-config
git status crates/meter-relay-rs     # untracked new files are invisible to Nix
git add -A crates/meter-relay-rs     # at least stage any NEW file — see below
git commit -m "…"                    # optional
# (a standalone `nix build` of the package is in the crate README)
sudo nixos-rebuild switch --flake .
sudo nixos-confirm                   # grafton-router has autoRollback — see the top
systemctl status meter-relay && journalctl -u meter-relay -f
```

- **A configuration-only change needs a rebuild, not a special path.** Editing
  the `plant` attrset changes no Rust code, so the built `ExecStart` is
  unchanged; `scripts/deploy-meter-relay.sh` will stop at "build is unchanged —
  nothing to deploy" and *not* switch — use `./scripts/deploy-meter-relay.sh
  --force`, or by hand `sudo nixos-rebuild switch --flake . && sudo
  nixos-confirm`. There is no restart-only path any more: the old `.env`
  shortcut is gone.
- **Verify the running build, don't assume:** `grep ExecStart
  /etc/systemd/system/meter-relay.service` must show the same store path the
  `nix eval` above printed, and `curl -s http://127.0.0.1:8484/api/status`
  should show the new fields (e.g. the PID `"saturated"` flag and the “at limit”
  badge added 2026-09-22).
- **An inverter can be effectively dead with nothing failing.** The relay learns
  what each inverter actually delivers/accepts and clamps the loop to that
  estimate — and because every rule only revises an estimate *down* to what was
  delivered, an inverter that delivers **nothing** at the command it is given
  gives the estimator no evidence to grow on, so the loop never asks for a
  command big enough to stir it. It sits there for as long as the process runs,
  raising no error and logging nothing; the only symptom is a number sitting
  still. Recognise it by an inverter whose `charge_limit` **and**
  `discharge_limit` are both *exactly* `150` (`= AUTHORITY_MARGIN_W`) with
  `battery_power` 0 while the grid is off target. On 2026-09-26 the Solax reserve
  sat like that for five hours *during the Go window*, at 17% SOC, delivering
  0 W — so the plant charged at 3.6 kW instead of 4.6 kW and the reserve failed
  to refill. Fixed in the relay (see `crates/meter-relay-rs/CONTROL-DESIGN.md`):
  a
  silent plant is now offered a ladder of larger commands every 30 s, and the
  60 W/s authority probe integrates over real time instead of over the PID's
  clamped step — that second one was also why the same window's charge crawled
  at 7 W/s and took 17 minutes to reach its rating. Reasoning, the regression
  table, and the diagnostic one-liner: `crates/meter-relay-rs/CONTROL-DESIGN.md`
  §2 and §7. **A relay restart clears a collapsed estimate** (the
  estimates initialise at the configured rating), which is the stopgap if it
  happens again before a rebuild.
- **A healthy inverter can be throttled by the estimator's own conservatism.**
  Because the central loop's ceiling *is* the learned authority, a plant whose
  charge ramps slower than the estimator's `DELIVERY_PROGRESS_W` (50 W inside the
  3 s confirm window = ~17 W/s) is read as refusing, the estimate collapses to
  `delivered + 150 W`, and the command then sits only ~150 W above the plant —
  so the plant ramps at ~6 W/s and the estimate can never grow faster. On
  2026-10-01 the Solis's `charge_limit` crawled 1.4→3.6 kW at ~6 W/s in **both**
  the Go window and midday PV; because the command tracked the estimate, actual
  `battery_power` tracked it too, and a sunny-cloudy afternoon exported surplus
  it could have stored. Diagnose with `solis_charge_limit` rising a few watts a
  second while the central PID is saturated (`saturated: true`, output ==
  min_output) and the grid exports. Fixed by lowering the progress threshold to
  10 W (`crates/meter-relay-rs/CONTROL-DESIGN.md` §2); the regression is
  `a_slow_charging_plant_is_not_throttled_to_its_own_lag`. A relay restart still
  clears a collapsed estimate as a stopgap.
- **The main bank still has no discharge floor, and `MR_SOLIS_MIN_SOC` will not
  give it one.** The Solis exposes no SOC register, so the relay cannot see the
  pack's state of charge at all (`"percentage": null`); it discharges until the
  JK BMS's own undervoltage protection cuts it off. Setting `MR_SOLIS_MIN_SOC`
  looks like the fix and is inert — it makes the slot *claim* to sense SOC, so it
  seeds at 50 % and then never updates, and the floor compares against that
  constant forever. That is how the bank was walked to 0 % on 2026-09-26 (BMS 2
  raised `Discharging undervoltage` and YaMBMS zeroed the discharge request, so
  the house imported ~1 kW for hours against a saturated PID). Closing it needs
  the BMS's SOC ingested into the relay, not a config knob. See
  `crates/meter-relay-rs/CONTROL-DESIGN.md` §2 "Known gap".

**Failure mode 1 — “I rebuilt but the input still runs the old code.”**
This **no longer applies to meter-relay-rs** (it is built from this repo now),
but it is still the rule for the other `path:` flake inputs (`gc-rust-node`,
`frigate-monitor`, the `llama.cpp` forks). Such an input is frozen at the
`narHash` recorded in `flake.lock`, so `nixos-rebuild switch` happily rebuilds
the *old* snapshot; because the resulting `ExecStart` is unchanged, systemd does
not even restart the unit, and the service keeps running the previous binary
with no warning. `nix flake update <name>` first, then compare the store path.

**Failure mode 2 — `vite build` / rustc says a new file does not exist.**
`error during build: Could not resolve "./Tip" from "src/App.tsx"` was exactly
this: `web/src/Tip.tsx` existed in the checkout but had never been added to git.
**New files must be at least staged (`git add`), or Nix cannot see them.** Nix
reads a flake's own directory through the **git fetcher**, which copies only what
git's index knows: tracked files (modified or not) *and staged ones*. A file
that is merely untracked is absent from `/build/source`, so the build fails on a
module that is plainly there in the working tree. Staging is enough; committing
is tidier. This applies to anything the build reads — `src/*.rs`,
`web/src/*.tsx`, `nix/package.nix`.

Note that because the crate now lives **inside** this repo, this flake *is*
git-filtered: a new file must be staged (failure mode 2) and `.gitignore`d build
junk (`target/`, `web/node_modules/`, `web/dist/`) is **not** copied into the
build. Keep `git status` in the crate clean-ish, so the working tree that Nix
reads corresponds to something reviewable.

### Incident 2026-11-27 pm — the bridge behind the ports (inverter-pi)

While closing out the morning's FTDI loss, the plant died a second time, and the
forensics took hours because **every layer below the relay reported healthy**:
`/api/connections` showed all three ser2net lines `online`, the relay's TCP
sessions were rock-steady (`d_conn=0` churn gone), and the grid meter was
answering 13 polls/s. What was actually down was inverter-pi (`.30`), which is
**not in this flake** and runs a Buildroot appliance image: a Raspberry Pi
(armv6, dropbear, host keys that regenerate → the `REMOTE HOST IDENTIFICATION
HAS CHANGED` warnings on router and zen3 are *normal* after its reboots) with a
USB hub carrying **three serial-numberless CH341 adapters**, `ser2net.yaml`
mapping `2000→ttyUSB0, 2001→ttyUSB1, 2002→ttyUSB2`, and **no NTP** (`date` is
1970; never trust its logs for timing).

Sequence: its USB/serial side died underneath a live system ~11:12–11:15 (the
meter legs of both inverters went silent minutes apart — a shared component,
the hub/bus; TCP still accepted, which is why the relay called it `online`), a
Solis power cycle at 11:19 landed into the dead bridge and latched `Meter COM
Fail`, and a pi reboot at ~12:26 restored the adapters but nothing answered,
because **the relay's own connection to ser2net had been `kill -9`'d earlier by
me during debugging** — ser2net forks a child per connection and *orphans keep
the flock on the serial device*, so the re-exec'd ser2net accepted TCP and
never opened `/dev/ttyUSB0`/`1` behind it. The tell: `ls -l /proc/$(cat
/var/run/ser2net.pid)/fd | grep ttyUSB` showed only `ttyUSB2`. Recovery was
`killall ser2net` (busybox: no `pkill`) **with meter-relay stopped**, then
start both: both inverters resumed polling within seconds and the Solis
cleared `Meter COM Fail` → `Generating` on its own — a latched meter fault
clears the moment the emulated meter answers again, no inverter power cycle
needed once the bridge is truly alive.

Lessons kept load-bearing:

- **`state: online` means a TCP socket exists, nothing else.** A bridge that
  accepts connections and forwards zero bytes is indistinguishable (to the
  relay) from a healthy one — the real liveness signal is `rx_frames` on a
  *master-side* line: on the solis/solax lines the relay is a Modbus **slave**,
  so silence there is the inverters' fault state, while on `stats`/`meter` the
  relay is the master and its own unanswered polls (`d_tx>0, d_rx=0`) name the
  dead leg. **Follow-up gap:** `alerts.rs` watches link *state*, so the
  11:15–13:05 window — hours of a frozen plant — produced no push. An
  "established but silent" rule for master-side lines (no `rx_frames` growth
  for N×poll-interval while `tx` is climbing) is the fix.
- **Never `kill -9` ser2net while a client is connected**; stop the client
  (meter-relay) first, or the orphan children hold the device flocks and the
  replacement accepts-but-doesn't-bridge.
- Both inverters sit behind that one pi/hub. If the pi's TCP stack stays up
  while its USB side dies, everything downstream is silent-but-`online` — check
  `ls /proc/$(cat /var/run/ser2net.pid)/fd` for all expected `ttyUSB*`, and
  `dmesg | grep -cE 'disconnect|now attached'` for hub flapping, **before**
  touching inverters or CTs.
- The pi's own enumeration story is the morning's lesson one layer down: three
  identical CH341s, no `/dev/serial/by-id`, port→`ttyUSBn` is boot-order luck.
  It happened to survive this reboot stable (dmesg probe order followed hub
  ports `.3.1/.3.2/.3.3` → `ttyUSB0/1/2`), but a swap would silently serve the
  Solis's meter frames on the Solax's line. If the appliance config is ever
  touched, map by hub port path (`/sys/bus/usb/devices/1-1.3.x`) instead.

