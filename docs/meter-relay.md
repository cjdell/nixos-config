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

### The second Solis joins (2026-11-27 evening) — three-phase dialects and an inert plant entry

The plant is now declared as **`solis,solax,solis2`**. The second Solis (an
S6 hybrid, battery pack analogue-connected at 48.9 V, **no battery CAN yet**,
AC wiring *temporary — current-limited*) taught the relay its first lesson
about meter **dialects**:

- Its stats side answers at **slave 3** with exactly the sibling's 33xxx map
  (`MR_SOLIS2_DRIVER = "solis"` works unmodified).
- Its **meter port** speaks the Eastron **SDM630** three-phase input-register
  map, measured by listening to it hunt (`solis2-listen`, 12 s answered
  nothing): `fc4 0x00 n6` phase volts, `fc4 0x0C n6` per-phase active power,
  `fc4 0x18 n6` per-phase reactive, `fc4 0x34 n6` the totals block — total
  P@52/S@56/Q@60 — the last at **~100 Hz while no meter answers**, so the
  old single-phase "pass-through from cache" emulator would have served the
  8217-lesson registers at the wrong addresses, held the nudge at a register
  this inverter never reads, and answered its totals with **zeros**.
- The fix is `MeterDialect` (`meter.rs`): each line declares where
  volts/amps/watts/var/VA/energy sit **in the inverter's space** plus a
  `copies` table (L2/L3 mirror L1; totals mirror the cache). Every position
  carrying active power is a legal nudge point and gets the same value, so a
  bulk read stays internally consistent (sum of phases == total — the
  cross-check that latched 8217 once). `MR_<ID>_METER_DIALECT = "sdm630"`,
  default `eem` = the historical map, byte-identical to before for the two
  live lines (regression-tested).
- The S6's meter line is a **fourth ser2net endpoint, `:2003` → ttyUSB3**,
  and the adapter there is an **FT232R, not a CH341** — the pi's Buildroot
  kernel carries `ftdi_sio.ko` but nothing loaded it (the image auto-loads
  no modules; `/etc/init.d/S02modules` grew a `modprobe ftdi_sio` line next
  to ch341). No buildroot rebuild was ever needed: the `.ko` has been on the
  pi the whole time. The new adapter sits on the LAN9512 hub (`1-1.2`), not
  on the flapping external hub.
- **`MR_SOLIS2_NUDGE_LIMIT = "0"` and all power budgets zero make the entry
  inert** (it was inert 2026-11-27 evening; armed charge-only on the night of
  2026-11-28 — see *The S6 reports the BMS, not itself* below, which found it
  had in fact never acted): the relay serves this line the *honest* grid
  reading (so the S6 stops faulting its meter and everything about
  discovery/telemetry/HA entities can be verified) but has no authority to
  steer it — the nudge on the phantom meter is the relay's *only* control path.
  Arming it later is raising `NUDGE_LIMIT`/`MAX_*`/`CHARGE_POWER`, and **first**
  confirming its meter-power sign convention (`MR_SOLIS2_REVERSE = "true"`
  follows the vendor doc's "+ = to grid", unverified on this model): serve a
  known grid power, read the inverter's own `Meter Active Power` block at
  **33130-33131** (33128 volts / 33129 amps alongside), and check the sign. The
  12-second listen-and-block-read scripts live in `/tmp/opencode/solis2-listen.py`
  style: stop meter-relay, single client per ser2net port, read-only FC04.
- Discovery now distinguishes three meter lines whose polls **share start
  addresses** (both Solises bulk-read from 0x00; the S6's per-phase power
  read sits where the Solax's total-power read sits) purely by register
  COUNTS — `MR_SOLIS2_METER_POLL = "4:0:6,4:12:6,4:18:6,4:52:6"`; the
  shuffled-port regression test is `three_overlapping_meter_lines_place_by_fingerprint_not_by_hint`.

### The S6 reports the BMS, not itself (2026-11-28, the night the phantom was found)

The charge-only arming that night was **wrong about what the S6 was doing**, and
the dashboard was why: solis2's `battery_power` tracked its allocator share to
within a few percent, so the plant looked like three inverters charging. It was
one inverter charging and one inverter **echoing the shared bank's CAN data**.

The proof is arithmetic. `meter_power − house_load − solis1 − solax` with the
house at its measured ~940 W leaves **0 W** for solis2, on every sample of the
Go window (2387−940−1482 = −35, 3388−940−1480−1001 = −33, 3250−940−1184−997 =
+129, …). If solis2 were really moving the 0.7–1.4 kW it reported, the plant
needed 1.8 kW of house load to balance, and the house does not draw that at 01:00.

The register map explains it (`solis_modbus` definitions + the Solis hybrid
protocol):

| register | meaning | solis1 | solis2 |
| --- | --- | --- | --- |
| 33133 / 33134 | battery V / A, **the unit's own** | 51.1 V / 15.0 A | 50.4 V / 13.7 A |
| 33141 / 33142 | battery V / A **from the BMS (CAN)** | 50.94 / 13.5 | 50.94 / 13.5 |
| 33143 / 33144 | BMS charge / discharge current limit | 15.0 / 81.0 | 15.0 / 81.0 |
| 33149-50 | battery power, **S32 magnitude + 33135 direction** | −766 W | +690 W |
| **33151-52** | **Inverting Power — AC port, +to grid/−from grid** | **−866 W** | **−5 W** |

`33141-33144` are **identical on both units** — that is the one CAN stream
YamBMS sends to the whole bank, and the S6's battery block (33133/34/49) is
that stream times its own terminal voltage, not a DC shunt of its own. Note
33143 (15.0 A) is a *charge limit*, not a current: don't read it as one.

Two traps make this worse:

- **33149's sign convention is firmware-dependent.** This firmware reports a
  magnitude and puts the direction in `33135` (0 = charge, 1 = discharge) —
  and `33135` moves, so the relay's `status 0 => -power / 1 => power` rule makes
  the published number flap between −690 and +690 W while nothing changes.
  Upstream hit the same thing (`solis_modbus` PR #579: some S6 firmware reports
  a *signed* value instead, and applying the direction twice flips it).
- **The S6 reads the emulated meter but does not act on it** — it is still in
  its off-grid/bypass state from commissioning (status 4, "Bypass Inverter
  Running"), so no meter nudge can steer it. Until its grid standard / storage
  mode / meter setting are commissioned on the unit, solis2 is *not* an actuator
  no matter what the relay commands.

**What the relay publishes now** (`sensor.<prefix>_inverting_power`, polled
from 33151 n2): the unit's own AC-port power, which is the only per-unit
measurement that is not the BMS. On the HA Overview dashboard both Solises show
that as *actual (AC port)*; the two `battery_power` rows stay, labelled
`battery register` / `battery register (CAN echo)`, because the difference is the
diagnostic. `inverting_power` is also in `/api/status` as `inverting_power`.

**Read the truth from the AC side.** When a Solis looks like it is charging,
confirm with 33151 (or, for the S6, the balance above) before believing the
battery block. The `Meter Active Power` block (33128-33131) is only the
*external meter* the unit reads — on the S6 it stays near zero while our line is
served, which is itself the tell that the unit is not on-grid.

### The phantom closed a positive-feedback loop (2026-11-28, the night of the oscillations)

Arming solis2 with a phantom measurement did not just mislead the dashboard: it
made the plant oscillate. At ~04:18–05:29 the second Solis limit-cycled between
charging and **exporting** at its AC port:

```
time     grid_W  pid_out | solis tgt/batt | solax tgt/batt | solis2 tgt/batt dlim clim
04:22:16    2931       0 | -3540/-3528 |     0/    0 |  -150/ 628.0    0  150
04:22:36    8567       0 | -3600/-3612 |     0/    0 |  -150/4430.0    0  150
04:22:56    2900       0 | -3361/-3235 |     0/    0 |  -150/ 218.0    0  150
04:23:16    3956       0 | -3600/-3379 |     0/    0 |  -150/-4169.0   0  150
```

Measured from the recorder (2 s samples) over the Go window: **±3.9 kW at
solis2's AC port with a ~66 s dominant period, 166 large sign crossings in
4.4 h**, dragging the plant's grid flow between 1.6 and 8.6 kW. solis1 held
−3.6 kW the whole time, which is what excludes the central loop: no 66 s
component in the primary actuator, only in solis2 and in the grid meter that
follows it. (The ~10 s "period" an autocorrelation also finds on solis1 and on
the meter is the poll cadence aliasing, not a loop.) Cross-checked against the
grid meter at 04:38, which is a separate instrument: import 8550 W when solis2's
AC said −3089 W (charging) and 2150 W when it said +2900 W (exporting), with a
~1.15 kW house — the AC register's sign is real, and 33151 was the only signal
telling the truth while the battery block flapped ±6 kW.

Cost, from the same history: **16.21 kWh into the bank** (SOC 44 → 95 %), split
**13.61 kWh solis1 / 4.13 kWh net solis2** (6.42 in, 2.29 kWh *back out*). The
point of the second unit was more charge per night; it delivered a third of its
sibling's and fought the plant for four hours.

The algebra shows why it had to oscillate. The per-inverter loop is P-only on
the *emulated meter*:

```
error  = target − measurement           (both "positive = discharging")
nudge  = clamp(Kp · error, ±nudge_limit)
the nudge REPLACES the meter register the inverter polls, then REVERSE negates it
```

At 01:39, with target −1500 W and the phantom reading −6010 W: error +4510 →
nudge **+1353** → the S6 is shown −1353 W, i.e. *export*, so it stops charging
and dispatches. But that −6010 was mostly **solis1's** work. So every correction
solis1 made arrived at solis2's PID as its own error, solis2 answered at the
nudge limit, its real answer moved the bank, and the bank came straight back at
it. Gain ≥ 1, delay = poll + inverter ramp → the only stable solution left is a
limit cycle. The `clim 150` column is the same story on the allocator side: the
learned-authority governor was told "asked 1500 W, delivered −6669 W", so it
collapsed solis2's charge authority to `AUTHORITY_MARGIN_W` (150 W, the floor)
and re-probed (−1119, −940, −723 …) only to collapse again — which is also why
the allocator never gave it a real share.

**The fix is `MR_<ID>_POWER_SOURCE=ac`** (`PowerSource` in `inverters.rs`): the
control measurement, the allocator's delivery observation *and the freshness
gate* move to the unit's own AC-port register (33151). Complete for this unit
because it has no PV strings and no load on its output, so every AC watt is a
battery watt (less ~8 % conversion). solis1 and the Solax keep `battery` — their
blocks are their own shunts.

**A measurement swap is a sign swap waiting to happen, so the sign is pinned by
tests, not argued** (`inverters.rs`, `inverter_controller.rs`):

- `both_control_sources_agree_on_the_sign_of_one_physical_flow` — for one flow
  direction, both sources must produce the same sign, charging *and*
  discharging. This is the "positive = discharging" contract the loops assume.
- `the_ac_source_is_not_run_through_the_status_word_negation` — the battery
  register's sign comes from `33135` (`status 0 => -power`); the AC register
  carries its own sign, so applying the status rule to it as well would measure
  the opposite and turn the loop positive-feedback with 1500 W behind it.
- `the_freshness_gate_follows_the_selected_source` — gate the register the loop
  reads, or freeze on a live signal / trust a dead one.
- `the_loop_corrects_towards_the_target_on_a_reversed_three_phase_line` — an
  under-charging unit is served *import*, an over-charging one *export*, through
  the live solis2-shaped line (`reverse` on, `sdm630`, total power at 52).
- `a_phantom_battery_figure_never_steers_the_loop` — the two sources are fed
  opposite situations; the served watts must follow the AC one. Fails the moment
  the bank echo is wired back in.

Startup also refuses a source a driver cannot produce: `supports_ac_power()` is
false for the Solax, so `MR_SOLAX_POWER_SOURCE=ac` is a startup error rather
than a silent fallback to measuring something else.

**Verified live 07:12 UTC, 3 minutes after the switch** (1 Hz sampler, solis2
asked for 0 W in balance mode): the PID's own `error` matched `target −
inverting_power` within 50 W (20 W deadband + poll skew) and the phantom by a
margin of 1775 W — the loop is measuring the AC port. solis2 sat on its set
point: **mean 1 W, range −29…+39 W, stdev 21 W** (that is 0.5 % of the ±3.9 kW
it was swinging an hour earlier), grid stdev 50 W against the 948 W the same
sampler recorded pre-fix, and regressing Δ(AC measurement) on the error that
produced the nudge gives **slope +0.57, r +0.45**: the unit moves *towards* the
target. The phantom still reads 1584 W — the bank, unchanged — and now steers
nothing. The charge ceiling is no longer collapsed either: `charge_limit` reads
3600 W, so tonight's window is the first real test of solis2's share.

**The dashboard was the last liar (same morning, 07:20).** An hour after the
switch the relay's own dashboard still showed **both** Solises discharging
~1.8 kW while `sensor.solis2_inverting_power` read 0 W and the BMS agreed with
the AC side: solis1 was discharging 1804 W DC (1579 W AC) and solis2 was idle,
its panel printing the phantom, `battery_power` = 1771 W = the bank. The switch
had moved the *loop*'s measurement and left the *picture* behind, which is the
same failure mode as last night in a different costume: a panel showing a figure
no part of the plant acts on. `/api/status` now carries `control_power` (what the
loops measure) and `power_source` (`battery` | `ac`) per inverter, and every
panel figure — headline number, charging/discharging/idle badge, the "refusing"
note, the reserve sums, the chart series — reads `control_power`. An AC-source
unit says so and shows the phantom as an amber note ("battery register reads
1771 W — that is the shared bank"), so the diagnostic stays visible without
being load-bearing. Note the AC figure is legitimately **larger** than the DC one
when discharging (1579 W at the wall from 1804 W out of the bank here) — that is
conversion loss, not missing power, and the panel's Tip says which end is which.

**And the page itself could not be trusted to reload.** `ServeDir` answers with
`last-modified: 1970` (Nix normalises store mtimes) and the router sent no
`Cache-Control` and no `ETag`, so every deploy looks identical to a browser and
heuristic freshness hands a 1970-stamped `index.html` about 56 years of
validity: the corrected panel above was live and the page still showed the old
one until a hard refresh. Three classes, three policies (`web.rs`): `/assets/*`
is content-hashed, so `public, max-age=31536000, immutable` — a cached copy can
never be the wrong copy; the entry document and the SPA fallback get `no-cache`
(revalidate every load, the file is ~1 KB); the JSON endpoints get `no-store`,
because a browser-rewound `/api/status` is the same class of lie as a stale
bundle. Verified from the live host: `/`, `/index.html` and an SPA route answer
`no-cache`, `/assets/index-*.js` answers `immutable`, `/api/status` and
`/api/connections` answer `no-store`.

### The primary group: both Solises share the discharge (2026-11-28)

The reserve model assumed **one** primary actuator (`index == 0`). With solis2
wired, commissioned and driven by an honest AC measurement the plant wanted
something else: both Solises on line for every discharge, **dividing it**. The
positional rule could not say that, and water-filling two units on one bank is
the wrong shape anyway — it pours everything into the first and leaves the
second idle until the first runs out, which is the single-unit wear a second
inverter exists to avoid.

So `primary` became a policy flag (`MR_<ID>_PRIMARY`, defaulting to the first
entry so no other host changes) and the allocator now speaks of a **primary
group** and a **reserve group**:

| | |
| --- | --- |
| Within the group | demand **divides in proportion to each member's observed authority** — 2.2 kW through the 3.6 kW and the 3.0 kW unit is 1.2 and 1.0 kW, not 2.2 through the first |
| Group limit | the **sum** of the members' authority. The wake test compares `needed` against that, so the Solax now wakes past ~6.6 kW instead of past one unit's 3.6 |
| The reserve | water-fills only what the group could not cover; same wake delay and release hysteresis |
| Proportional, not equal | a member whose authority collapses (tapering pack, dead line — the failure the phantom taught us about) automatically carries less instead of being commanded power it cannot deliver |
| No primary at all | `Allocator::new` promotes the first entry: a plant with nothing on line cannot control the grid, and the flag makes that misconfiguration reachable for the first time |
| Telemetry | `ReserveState` codes kept verbatim (`solis_only` now means "the group alone"); `primary` per inverter is in `/api/status`; `sensor.solax_authority` follows the inverter **called** `solax` rather than index 1 — which since the group arrived is the second Solis, so the old positional code would have published solis2's authority under the Solax's entity id, silently, to anything automating on it |

Deployed plant: `solis,solis2,solax`, `MR_SOLIS2_PRIMARY=true`, ceilings **and
nudge limit** at the unit's 3.0 kW rating. The nudge limit matters as much as
the ceiling: it is the inner loop's only lever, so a 1500 W clamp caps the
command no matter what the allocator asks, and the authority learner then reads
the shortfall as the battery refusing power and collapses the unit's limit to
its 150 W floor — last night's signature, self-inflicted.

#### Two start-up bugs the group exposed (same deploy)

Deploying the group made solis2 freeze at **163 W of discharge authority for as
long as it was watched**, meeting every command it was given — and the freeze is
the interesting part, not the collapse:

- **The recovery path was unreachable.** `AuthorityLimit` relaxed its estimate
  back toward the rating only while the loop was *leaning on the estimate*
  (`commanded >= value - 50`). Under water-filling a primary is always asked for
  the whole remaining demand, so that held. Under a **proportional** split a
  member's command is only its share, usually far below its own estimate, so the
  relax could never run: never asked for the power that would prove it had
  recovered, therefore never allowed to recover. Fixed by a second way to earn
  authority — real power flowing (`>= 20 W`) and the command met — and the gate
  is deliberately on **delivery, not command**: gating on the command re-creates
  the same dead zone one level down, because a starved member is asked for little
  *because* its estimate is low. What keeps an over-optimistic climb honest is
  the deficit path, which snaps the estimate to observed delivery 3 s after a
  command stops being met.
- **The collapse itself was a start-up race.** The split hands an inverter its
  demand the instant the relay starts, but that unit's own loop still has to wind
  its nudge up from zero through the S6's meter-driven current control: seconds.
  Measured — 3.0 kW ceiling to the 163 W floor in under 4 s after the restart.
  A `grace_until` window (15 s, restarted when a measurement gap closes, since
  the loops start over there too) treats a gap inside it as a ramp: the stall
  clock is pushed out and the baseline tracked, and **no conclusion is drawn**.
  It is a head start, not a pardon — `a_command_the_plant_has_not_had_time_to_act_on_is_not_a_refusal`
  pins that a plant still refusing at 40 s is collapsed exactly as before.

Both are pinned by tests rather than by reasoning (`a_group_member_asked_for_less_than_
its_authority_still_recovers_it`, `a_command_the_plant_has_not_had_time_to_act_on_is_not_a_
refusal`), and the ordering matters for anyone reading this later: with the earn-floor at
300 W the first test still failed at exactly 300 W, which is what showed the floor was in
the wrong place.

#### What the full bus probe changed

`probe-statsbus.py` (scratch, `/tmp/opencode`) sweeps 33000-33259 (fc4) and
43000-43159 (fc3) on **both** Solises at the same instant and prints where they
differ. It replaced three assumptions:

- **No rated-power register exists on the bus**, and the two units share one
  register map — every difference is a measured quantity, a counter or a
  setting. The ceilings therefore come from the owner's spec (unit 1 = 3.6 kW,
  unit 2 = 3.0 kW, newer revision), *not* from the wire; what actually binds is
  learned per unit plus the BMS broadcast. Saying so in the config beats letting
  a copied 3600 imply a measurement.
- **The pack's limits are identical on both**: 33143/33144 (CCL/DCL) read 81.0 A
  on each — the same CAN value, because the bank has one BMS. At 52 V that is
  4.2 kW, above either rating, so neither unit is BMS-capped at its own ceiling,
  but **the pair is capped by the pack**: 3.6 + 3.0 kW is ~125 A through
  terminals whose DCL is 162 A. Hence tandem discharge is watched as a *bank*
  quantity (the overnight watchdog now alerts above 150 A and on YamBMS
  `dcl_derating_reason`, which is the BMS admitting it cut the inverters).
- solis2's `Max-Grid-Charge-Current` is **30 A** (43074, mirrored at 33247)
  against solis1's **99 A** — a charge cap near 6.9 kW, i.e. not the constraint
  the earlier config comment believed it to be.
- **The phantom, caught in the act**: solis2 idle with its sibling discharging
  1.7 kW, solis2's 33134 read 36.7 A — equal to its own 33142, the BMS's *bank*
  current, to 0.1 A — and its 33149 pair computed 1919 W from that borrowed
  current at its own 52.3 V, while 33151 (AC port) read **0 W**. solis1's 33134
  (37.4 A) matched its own 1963 W at 52.5 V, and its 33151 read 1717 W. The
  battery block is a shunt on one unit and a CAN echo on the other; only the AC
  register tells them apart. "Idle but reading power" is a signature worth
  re-checking whenever a battery figure on this plant looks merely plausible.

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

