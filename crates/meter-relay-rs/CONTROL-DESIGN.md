# Control design: priority allocation, learned authority, honest metrics

This is the implementation companion to [`CONTROL-REVIEW.md`](CONTROL-REVIEW.md).
The review's verdict was that the objective, the cascade and the PID are sound,
and that what is left is *implementation*: an allocation that wears out a 1.4 kWh
battery for load a 29 kWh bank could carry, a derivative term that was 41% of the
output variance and nothing of the plant, a mode switch that stepped 6 kW in one
tick, metrics that described noise, and a loop that spent its authority asking
for power the batteries were refusing.

Each of those is addressed below. The one structural change — the thing the
review called "the one change with a defensible rationale" — is that **the fixed
2:1 split is gone**, replaced by a priority split in which Solis is asked for the
whole demand and Solax is a reserve that wakes only when Solis demonstrably
cannot cover it.

## 1. Allocation: a priority list of inverters

`src/allocation.rs`, exercised end-to-end by the simulated plant in
`src/control.rs`.

The plant is a **priority-ordered list** — index 0 is the primary actuator,
everything after it is the reserve group — and the same water-filling rule runs
in both directions:

```
                       ┌─ inverter 0: min(remaining demand, its authority)  ← always
discharge demand ──────┤
                       └─ inverter 1..n: the remainder, clamped to each     ← only while
                          one's own authority                                engaged

                       ┌─ inverter 0: min(remaining surplus, its charge authority)
PV surplus ────────────┤
                       └─ inverter 1..n: the remainder, up to each one's    ← whenever it is
                          charge authority and below its SOC ceiling        below that ceiling
```

Nothing in the allocator names an inverter: it walks `AllocatorConfig::inverters`,
so a third battery is a configuration change (`MR_INVERTERS`) plus a driver
(`inverters::build`), not a rewrite of the control law.

The reserve is *engaged* for **discharge** when, and only when, both of these
have held continuously for `MR_RESERVE_WAKE_DELAY_MS` (1.5 s; the older
`MR_SOLAX_WAKE_DELAY_MS` spelling still works):

* the demand sits at the primary-only authority (`needed ≥ A_primary − 50 W`), and
* the grid is off target by more than the control deadband plus
  `MR_RESERVE_WAKE_ERROR` (120 W).

The first half is what makes this "demand that cannot be met by the primary
alone" rather than "a big number appeared"; the second half is what stops a
transient that the loop is already closing from waking the reserve. It is
released after `MR_RESERVE_RELEASE_DELAY_MS` (30 s) of the demand sitting
`MR_RESERVE_RELEASE_MARGIN` (250 W) *below* the primary's authority, so the
boundary does not chatter.

Consequences, all of them intended:

* Ordinary house load is carried entirely by the main bank. The reserve sits at
  zero, its firmware holding its own output down against a phantom meter reading
  of zero.
* A kettle or an oven only wakes the reserve if the primary is genuinely short —
  and then only after 1.5 s of confirmation, so a 2 s transient costs a trickle
  of import rather than a battery cycle.
* If the main bank is empty (or its inverter derates), the reserve takes over,
  because the authority estimate below collapses and the demand reaches the
  collapsed limit.
* Below `MR_<ID>_MIN_SOC` (15%) a reserve is not discharged at all; it is
  refilled from cheap grid energy in the Octopus Go window — and now from
  surplus as well — which is what keeps it available as a reserve.

### Surplus also charges the reserve

**This deliberately reverses the review's "charging stays with Solis" rule for
the reserve.** The review's tariff argument — export at 12p beats storing against
an 8.5p Go import by 3.5p/kWh — is about a battery whose stored energy would
otherwise have displaced *Go-rate* import. It does not hold for the reserve,
because the reserve is only ever discharged to cover demand the main bank cannot:
the energy it holds displaces peak-rate import at ~29.84p. Storing midday surplus
in the reserve therefore nets roughly **+17.8p/kWh against exporting**, whereas
the same kWh in the main bank nets −3.5p. That asymmetry is why the main bank
still takes the surplus first, and why the review's "do not fix this by making
the batteries absorb" stands for the main bank.

The spill is self-limiting, which is what keeps the economics bounded:

* the main bank is filled first, so behaviour is unchanged whenever it has charge
  headroom;
* only surplus its *learned* charge authority cannot accept spills down the list
  — a pack tapering at 93–95% SOC accepts a few hundred watts;
* a reserve at `MR_<ID>_MAX_SOC` (95%) is skipped entirely, so it can never hoard
  an afternoon's export;
* if the reserve is never discharged during peak hours, the absorbed kWh was
  worth only the 8.5p of Go import it displaced. The trade is made to guarantee
  the reserve is *available* for a spike, not because every absorbed kWh is
  profitable on its own.

`MR_<ID>_ABSORB_SURPLUS=false` restores pure export for an inverter — the
one-line revert if that trade ever needs revisiting.

## 2. Authority is learned, not assumed

The review's charge table is the reason this exists: at midday the loop asked
for a mean −1861 W of charge and 179 W was accepted (0.06 authority at −3.6 kW),
so the output sat pinned against a limit that did not exist.

Every inverter now carries two estimates — one per direction — of what it
actually delivers/accepts, smoothed the same way as the command it is compared
against (0.5 s). A gap of more than 150 W sustained for 3 s revises the estimate
down to what was delivered; a plant that keeps up lets the estimate relax back
towards its configured rating at 60 W/s, but only after a 20 s hold and only
while the loop is leaning on the estimate, so an idle direction does not drift
upwards unattended.

Three properties of that rule are load-bearing, and they were learned in the
field on 2026-09-26 and 2026-10-01:

* **The probe is integrated over real time, not over the PID's step.** 60 W/s is
  a physical rate, so it is multiplied by the loop's *actual* elapsed time.
  `MAX_STEP_SECONDS` (0.25 s) exists to keep one late tick out of the PID's
  integral and must not be reused here: the loop is paced by its own I/O, and
  applying that clamp to the probe scales it down by the ratio of the loop's
  period to the clamp. At a 2 s tick the probe ran at 7 W/s, which is why the
  Go-window charge took 17 minutes to reach its rating. `AUTHORITY_MAX_STEP_SECONDS`
  (2 s) bounds the probe instead.

* **A plant that delivers *nothing* gets a way out.** Every other rule here can
  only revise an estimate *down* to what was delivered, and the loop then asks
  for no more than that — so a device that will not act on the command it is
  given is never offered one it would act on, and it is stranded for as long as
  the process runs. That is exactly what a command below a device's minimum
  start power looks like: the reserve was found with both its limits pinned at
  the 150 W margin and delivering zero for five hours. A silent plant (asked for
  power, delivering none) is therefore offered a ladder of larger commands, one
  rung per `AUTHORITY_REPROBE_MS` (30 s), doubling up to its rating; the ordinary
  collapse logic pulls the estimate straight back down if it still does not
  answer, so a wrong guess costs a brief over-command rather than a standing one.
  In balance mode the escalation only raises a *permission* — the split still
  caps each inverter at what the demand needs — so the only command it actually
  raises is the open-loop Go-window charge, which is the one that must not be
  left asking for too little.

* **The progress test must be smaller than any real ramp.** A deficit is only a
  refusal when the delivery *stops closing* the gap, so the rule resets the
  confirm clock whenever delivery rises by `DELIVERY_PROGRESS_W`. The first
  value, 50 W, demanded ~17 W/s inside the 3 s confirm window — faster than the
  live Solis charges. On 2026-10-01 its learned charge limit crawled from
  ~1.4 kW to its 3.6 kW rating at ~6 W/s in **both** the Go window and midday
  PV, at ~7 minutes each way, so a sunny-cloudy afternoon exported the surplus
  instead of storing it. Because the command *is* the estimate (the central loop
  is saturated on it), collapse pinned the command ~150 W above the plant and
  the plant then only ramped as fast as that small gap drove it — a
  self-limiting ratchet, indistinguishable from an inverter soft-start except
  that the Go window (where the command is open-loop full) showed the same
  crawl. 10 W is above the smoothed battery-power noise floor and below a
  6 W/s ramp's progress in a confirm window, so the probe now runs at its own
  rate and the plant ramps at whatever rate it can actually sustain.

Those estimates *are* the central loop's output clamp, refreshed every tick
(`ControlLaw::tick_balance` → `Allocator::limits`):

* discharge authority = Solis alone while the reserve is out, Solis + reserve
  while it is engaged;
* charge authority = Solis alone, by the tariff argument above.

The loop therefore cannot wind up against authority that is not on line — and
when a battery really is refusing, the clamp collapses to what it is accepting,
the output pins, and conditional integration freezes the integrator.

Because the clamp is now the *learned* authority rather than a fixed ±6 kW, the
integral bound changed with it: the integral term may use the whole live
authority instead of 25% of a fixed number. That is not a loosening of
anti-windup — the freeze against the live limit and the authority observer are
the anti-windup — it is what lets the loop hold a steady demand *inside* the
authority without a proportional error. With the old 25%-of-6 kW bound, any
steady demand above ~1.5 kW was met with a permanent error, and a permanent
error of a few hundred watts is exactly what the reserve's wake test has to
distinguish from a real shortfall. `pid.rs` has a regression test for this
(`integral_can_carry_a_steady_demand_inside_the_live_authority`).

### Known gap: the main bank has no SOC floor

An SOC floor can only be enforced on a device that reports SOC, and the Solis
driver deliberately exposes none — `soc_regs()` returns `None`, because the
pack's SOC lives in the JK BMS in Home Assistant, not in that register map. The
main bank therefore has **no floor at all**: it is discharged until the BMS's own
undervoltage protection cuts it off, and the BMS is the only thing standing
between the pack and empty.

That is what happened on 2026-09-26. A ~7 kW house load held from 09:00 to 14:40
walked the bank from 93% to ~30%, the evening load finished it, BMS 2 raised
`Discharging undervoltage` at 20:02 and YaMBMS set the discharge-current request
to zero. The plant then sat importing ~1 kW for hours while the central loop
asked for a discharge the BMS would not give — a saturated PID against an
authority that was real but unusable.

**This is not a config change.** `MR_SOLIS_MIN_SOC` looks like the fix and is
inert: setting it makes `senses_soc()` true, so the slot seeds its SOC at
`SOC_UNKNOWN_SEED` (50) and then never updates it, because the only SOC it could
track arrives as `NaN` from a device that has no such register. The floor would
compare against a constant 50 forever, and discharge would never be stopped.
Closing the gap means ingesting the pack's SOC from the BMS (the YaMBMS or JK
value the relay already publishes to HA), after which the ordinary `min_soc`
mechanism works unchanged.

## 3. The loop itself

| Change | Why (review §) |
| --- | --- |
| Derivative on **measurement**, low-pass filtered, `MR_PID_KD=0` by default | §4.2 — D was 41% of the output variance, all of it above 10 Hz, differentiating the meter's 80 ms zero-order hold at a 10 ms tick. Differentiating the error also turned every setpoint step into a kick. |
| Dynamic output limits from the allocator | §4.1 — the loop asked for −3491 W of charge in the 14:00 hour while the bank accepted ~0. |
| Error deadband (`MR_CONTROL_DEADBAND=20 W`) that also gates the integral | §4.2 — with ±30–50 W of meter fluctuation, chasing the last 20 W is actuator churn for nothing. |
| Slew limit on each inverter's target (4 kW/s Solis, 1.2 kW/s Solax) | §4.3 — an 8 kW single-tick step in the Solis target; Solax's firmware dislikes steps anyway. |
| `reset_dynamic_state()` on the charge↔balance transition | §4.3 — the 6 kW single-tick command at 04:29:00 came from a stale error carried across the regime change. |
| Dead "if the PID goes insane, reset it" guard removed | §4.5 — unreachable once the output is bounded by real authority. |
| Metrics are running sums, not 100 Hz histories | §4.5 + memory: three `Vec<f64>` per PID at 100 Hz for an hour was ~25 MB of state to compute nine numbers. |

## 4. Metrics that describe the plant

`PidMetrics` is rebuilt around running sums and reports, per window (reset
hourly):

| Field | Meaning |
| --- | --- |
| `mean_absolute_error`, `root_mean_square_error` | as before |
| `peak_error` (W) | largest \|error\| — replaces `overshoot`, which divided the largest export excursion by a 50 W setpoint with a peak that never decayed (`691.9%` on a good day) |
| `in_band_percent` (%) | share of samples within ±25 W |
| `oscillation_count` | crossings outside ±25 W that stayed on the new side ≥2 s, so meter noise no longer counts (was 228/h of noise) |
| `actuator_energy_kwh` | ∫\|output\|dt — replaces `total_control_effort`, a bare sum over 100 Hz samples that reached 2.1e8 and grew without bound |
| `output_roughness` (W) | RMS per-tick output change (was `control_variability`, dominated by the D impulse train) |
| `current_error`, `slow_error` (W) | slow error is a 10 s mean, not the mean of the last 10 samples (100 ms) |

With `ki = 0` the per-inverter PIDs hold no integral state at all, so the
dashboard can no longer show a `-3.3e7 W·s` integral for a controller with no
integral action.

## 5. Instrumentation

* `relay` (100 Hz) gains `solis_nudge`, `solax_nudge` — review §6 step 1. With
  `kd = 0` these are the direct evidence that the impulse train is gone.
* New `allocation` measurement (1 Hz), tagged with the reserve state
  (`solis_only` / `waking` / `reserve` / `soc_floor` / `charging`), carrying both
  inverters' learned limits, the total authority, the reserve share, the unmet
  demand, Solax's SOC and both inverters' meter-request intervals.
* Register caches now carry a per-register timestamp, so "stale" is
  distinguishable from "zero": stale measurements are excluded from authority
  learning, a stale reserve cannot be engaged, and the dashboard flags it.
* Home Assistant gains `solax_reserve_state`, `solax_reserve_power`,
  `inverter_authority` and `solax_authority`.
* Reserve transitions are logged at INFO, so `journalctl -u meter-relay` tells
  the story of a day in a few lines.

## 6. Deliberately not done

* **Feedforward from load/PV.** The relay already reads the grid meter at
  50–80 ms, which is *faster* than the Solis load register (1 s), the Solax
  register (200 ms) and the HA Tasmota plug (1 s), and the P term acts on it
  directly. A feedforward from a slower copy of the same disturbance would add a
  path, not information. Review §4.4 caps the prize at "a couple of seconds of a
  ~500 W step".
* **MPC / day-ahead planning**, **ADRC**, **RL** — review §4.6 and §5. The
  financial ceiling is ~£22/year of peak-rate import and the current rule already
  is the profit-maximising one at these tariffs.
* **Smith predictor, gain scheduling** — the measured delay is inside the
  settling time, and the authority observer already handles the 10x gain
  variation with direction and SOC with less machinery.

## 7. Verification

```sh
cargo test          # 64 tests: PID semantics, allocator policy, and a closed
                    # loop against a simulated N-inverter plant
```

The `control::tests` module runs the real `ControlLaw` against a simulated plant
whose batteries are a `Vec` — so the tests themselves are evidence that the law
does not know how many inverters there are. The headline one is an hour of
scripted house load (base load, three sustained overloads beyond the primary's
authority, and a train of 1 s spikes) asserting that the reserve engages
**exactly three times** (once per sustained overload, never for a spike shorter
than the wake delay) and that its battery does not move at all under base load.
The rest cover the wake confirmation, the release hysteresis, the SOC floor, a
shortfall caused by an empty main bank, the surplus spill and its SOC ceiling,
`absorb_surplus = false`, a single-inverter plant, and a **three-inverter** plant
allocated correctly in both directions. `pid::tests` covers the deadband,
derivative-on-measurement, dynamic limits, the integral-authority regression and
the metric definitions.

The authority estimator carries its own regressions, because every one of them
is a field failure that cost real money and none of them is obvious from
reading the rule:

| Test | The failure it pins |
| --- | --- |
| `a_load_step_does_not_collapse_the_estimate` | the plant's own response time read as a shortfall |
| `a_lagging_plant_is_not_mistaken_for_a_refusing_one` | a transport delay + lag read as refusal (2026-09-23: the loop clamped to a fraction of a 3.6 kW rating with ~1 kW of import held for minutes) |
| `a_slow_charging_plant_is_not_throttled_to_its_own_lag` | a *slow* ramp read as refusal (2026-10-01: the Solis charge limit crawled 1.4→3.6 kW at 6 W/s, ~7 min, in the Go window and midday PV) |
| `a_slow_tick_does_not_slow_the_authority_probe` | the probe integrated over the PID's clamped step instead of real time (2026-09-26: a 17-minute ramp) |
| `a_silent_plant_is_offered_a_command_it_can_act_on` | a device pinned at the margin floor forever because it will not act on so small a command (2026-09-26: the reserve dead at 150 W for five hours) |
| `authority_collapses_when_the_battery_refuses_charge` | a genuine refusal must still collapse — the anti-windup the estimator exists for |
| `authority_recovers_slowly_once_the_deficit_clears` | recovery is slow and ceiling-respecting, not a step |
| `authority_ignores_stale_measurements` | a device that has stopped answering must not be handed demand |

Both 2026-09-26 rows are load-bearing in a way a reader would not guess: the
first is why a charge can crawl for a fifth of the Go window, and the second is
why a healthy inverter can be invisible to the plant for hours. Neither raises
an error anywhere — the only symptom is a number sitting still. The 2026-10-01
row is the same class again: a healthy Solis charging correctly, throttled by
the estimator's own conservatism, visible only as a charge limit that climbs a
few watts a second.

Operationally, watch:

```sh
curl -s http://127.0.0.1:8484/api/status | jq '{grid: .central.grid_power,
  reserve: .reserve,
  inverters: [.inverters[] | {id, target, discharge_limit, charge_limit, absorbing}]}'
journalctl -u meter-relay -f | grep "reserve state"
```

The dashboard's **Reserve** panel is the at-a-glance version: state, what the
reserve is covering, what surplus it is absorbing, what the grid is still short
of, and the learned authorities. A healthy ordinary day reads `standing by` with
a zero reserve output; a full main bank and midday sun reads `Surplus absorbed`
non-zero with the reserve battery trace charging below the zero line.

**What a stranded inverter looks like**, because it raises no error and logs
nothing — the only symptom is a number sitting still. Both directions of one
inverter sit at *exactly* 150 W, its target pinned at ±150, and it delivers 0 W
while the loop is plainly asking for power and the grid is off target:

```sh
curl -s http://127.0.0.1:8484/api/status |
  jq '.inverters[] | select(.charge_limit == 150 and .discharge_limit == 150) | {id, target, battery_power}'
```

150 is `AUTHORITY_MARGIN_W`, so a value parked there is the collapsed floor, not
a rating. Since the fix the ladder will walk it back up by itself within a
probe or two; if it is still there after a minute, the device itself is not
answering and the problem is on the inverter's side, not the relay's.

Tuning is a Nix change on a deployed host: every knob below is a setting in
`hosts/grafton-router/services/meter-relay.nix` (nixos-config), so `nixos-rebuild
switch` applies it. Only a *local* run reads them from the environment directly
(a `.env` in the working directory is a development convenience, nothing more —
there is none on the host):

| Knob | Effect |
| --- | --- |
| `MR_<ID>_MAX_DISCHARGE` | the level the demand must exceed to wake the reserve |
| `MR_<ID>_MIN_SOC` / `MAX_SOC` | how much of the reserve is protected / refilled |
| `MR_<ID>_ABSORB_SURPLUS` | whether this inverter takes PV surplus at all |
| `MR_RESERVE_WAKE_ERROR`, `_WAKE_DELAY_MS` | how eager the reserve is |
| `MR_RESERVE_RELEASE_MARGIN`, `_RELEASE_DELAY_MS` | how long it stays in |
| `MR_CONTROL_DEADBAND` | how much meter noise the loop ignores |
| `MR_PID_KD` | non-zero is now safe (filtered, on measurement) but measured useless |

## 8. What this changes on the recorded week (estimate)

Against the same 7 days of 1-minute `relay` data the review analysed
(2026-09-15 → 09-22, ~10 000 minutes):

| | recorded (2:1 split) | under this allocation |
| --- | --- | --- |
| Reserve discharge | 17.8 kWh / 7 d | ~0.5 kWh / 7 d — the rest is demand Solis alone was covering |
| Reserve charge | 25.4 kWh / 7 d | refill to `MR_<ID>_MAX_SOC` in the Go window after each engagement, plus any surplus the main bank's collapsed charge authority could not take |
| Minutes whose demand exceeded Solis's 3.6 kW ceiling | 42 of 10 055 (0.42%), 17 separate episodes | ~2.4 reserve engagements per day, each released 30 s after the demand falls back |
| Midday 11:00–16:00 | mean **3220 W** of charge requested while Solis's median charge acceptance was **0.01** | charge demand capped at the observed acceptance +150 W, so the output is not pinned for hours |
| Evening 17:00–23:00 tracking | grid −33 W mean, mean \|error\| 41 W | unchanged (the loop was already good there) |

The "demand exceeded the ceiling" figure is derived from the *old* loop's
output, so it is an effect-size estimate rather than a simulation of the new
loop; the closed-loop behaviour is what the `control::tests` scenario pins down.

## 9. Files

| File | Role |
| --- | --- |
| `src/allocation.rs` | priority water-filling in both directions, authority estimates, reserve state machine, slew, per-inverter policy |
| `src/control.rs` | `ControlLaw`: the tick, the PID/allocator wiring, the simulated-plant tests |
| `src/pid.rs` | deadband, derivative on measurement, live limits, online metrics |
| `src/config.rs` | the plant list (`MR_INVERTERS` + `MR_<ID>_*`) and per-driver defaults |
| `src/inverters.rs` | `InverterDriver` trait, the make/model register maps and the driver factory |
| `src/controller.rs` | I/O wiring, regime transitions, telemetry, Influx/HA publishing, per-inverter loops |
| `src/registers.rs` | register freshness |
| `web/src/App.tsx` | reserve panel, per-inverter panels, authority and request-interval readouts, honest metric labels |

The repository's `flake.nix` dev shell was also repaired in passing: `nodePackages`
was removed from nixpkgs, so `typescript` and `typescript-language-server` are
now referenced as top-level attributes (`nix develop` had been failing outright).
