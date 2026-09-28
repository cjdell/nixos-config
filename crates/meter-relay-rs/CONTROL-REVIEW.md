# Control review: is PID the right mechanism here?

> **Status — implemented.** The review's recommendations in §6 are in the tree:
> derivative removed/filtered, regime-change state reset, honest metrics,
> instrumentation, and (the structural one) the 2:1 split replaced by a
> priority split with learned per-inverter authority, in which Solax is a
> reserve that only wakes when Solis cannot cover the demand. What was built,
> and the tests that pin each claim, are in
> [`CONTROL-DESIGN.md`](CONTROL-DESIGN.md). The measurements below are left as
> they were taken.

**Question asked:** would a control mechanism other than PID be better for
`meter-relay-rs`?

**Short answer:** no single-loop replacement (ADRC, LQR, MPC-as-regulator, RL)
would buy much, because the measurements below show the binding limits are the
*actuator set* and the *allocation between the two inverters*, not the
regulation law. The outer loop is already fast and near-unbiased where the
plant can follow it. The available headroom is in three places, none of which is
"a better feedback law":

1. **Allocation** — one PID output split 2:1 across two inverters whose measured
   authority differs by ~3x, one being a much smaller battery. This *is* a
   control-mechanism problem, but it is an allocation/optimisation problem, not a
   regulation one.
2. **Feedforward** — the load and PV are already measured at 0.5–1 s; the loop
   ignores them and waits for the error to appear instead. Cheapest of the three
   to implement, though §4.6 caps what it can be worth.
3. **The derivative term and the mode switch** — measurably misfiring: D is 41%
   of the output variance, all of it above 10 Hz, with no visible physical
   effect, and it produces multi-kW single-tick command spikes on transients.

Two things the investigation *ruled out*, both of which looked promising before
the tariffs and the actuator data were checked:

- **"The midday PV surplus is being exported instead of stored"** is **not a
  defect**. With export at 12p/kWh against 8.5p Go import, selling the surplus
  and re-buying at night beats storing it by ~3.5p/kWh.
- **"Better grid tracking would save money"** is worth about **£20/year** — the
  balance-hour peak-rate import that the loop fails to avoid is 1.39 kWh/week.

So the remaining case for changing anything is **robustness (dead code, stale
state, misleading metrics) and actuator/battery wear**, not energy cost — and a
day-ahead planner, the one "heavier mechanism" that looked justified, is not
justified either once the tariffs are priced (§4.6, §5).

Everything below is measured from the live system, not inferred from the source.

---

## 1. What the control system actually is

This matters more than it looks, because the relay is **not** driving the
inverters' power directly. It is a cascade wrapped around the inverters' own
firmware loops.

```
grid meter (serial, Modbus RTU, f32 active power, polled ~50 ms nominal)
        │
        ├─► grid power ──► CENTRAL PID  (controller.rs:212)
        │                  kp=0.9 ki=0.3 kd=0.15, ±6000 W, runs every 10 ms
        │                  output = "needed_power"
        │
        ├─► needed_power split 2:1 (Solis 2/3, Solax 1/3)
        │        │
        │        └─► PER-INVERTER PID (P only: kp=0.3 Solis / 0.5 Solax, ki=kd=0)
        │             process value = that inverter's battery power
        │             output = a REPLACEMENT value for the meter's active-power
        │                      register, written into the Modbus response the
        │                      inverter reads (meter.rs:74, inverter_controller.rs:77)
        │                      i.e. the inverter is shown a phantom grid reading
        │
        └─► the inverter's own zero-export/self-use loop chases that phantom,
            and its output is what actually moves power
```

So the plant the central PID sees is `(outer PID) → (P loop) → (vendor firmware
loop) → (battery) → (grid)`, and the actuator command the vendor sees is a fake
meter value, not a power setpoint.

Loop rates (from `controller.rs:21-27`, `registers.rs`):

| Signal | Rate |
| --- | --- |
| Control loop | 10 ms (100 Hz) |
| Meter active power (actual refresh, measured) | ~80 ms (12.1% of ticks see a fresh value) |
| Solis battery power | 500 ms poll |
| Solax battery power | 200 ms poll |
| Inverter meter requests (drive the P loops) | event-driven, per request |

Charge mode is a separate open-loop branch (`controller.rs:201-205`): the central
PID is **not called at all** while charging; each per-inverter target is simply
set to `-MR_*_CHARGE_POWER`.

---

## 2. How this was measured

Data: the `relay` measurement in the InfluxDB `Meter` bucket (written by the
relay itself every 10 ms, plus `power,meter=grid` every 100 ms), 2026-09-15 →
2026-09-22. Windows used:

| File | Window / resolution | Used for |
| --- | --- | --- |
| raw 100 Hz, 5 min | 2026-09-22 10:10Z | tick-level behaviour, D-term attribution, spectrum |
| 1 s means, 2 h | 2026-09-22 09:20Z | excursion durations, error autocorrelation |
| 1 min means, 7 d | 2026-09-15 → 09-22 | per-hour tracking, authority by command sign/bins, pricing (§4.6) |
| raw 100 Hz, 20 min | 2026-09-22 04:20–04:40Z | the charge→balance mode switch |
| 1 min means, 8.5 h | 2026-09-21 07:30–16:00Z | Solax vs Solis discharge energy, to size the small battery |

Cross-checks: Home Assistant for SOC/PV/load (`sensor.yambms_yambms_1_battery_soc`,
`sensor.jk_bms_*`, `sensor.inverter_pv_power`, `sensor.solax_percentage`).

Tariffs used in §4.6 are the operator's actual ones: import 8.5p/kWh
00:30–05:30 and ~29.84p otherwise (the 29.84p figure is also hard-coded in
`controller.rs:332`), export 12p/kWh all hours. Note the export rate is *not*
known to the relay — the code prices only import.

Reproduce with `scripts/control_audit.py` (see §7) against CSVs exported from
Influx.

---

## 3. What is working

Be clear about this before changing anything:

- **Evening/afternoon grid tracking is good.** 17:00–23:00 local, 7-day:
  grid mean **−35.0 W** against a −50 W target (15 W bias), mean |error|
  **38.3 W**, median 8.4 W, importing 8.8% of minutes.
- **Most of the day is good; the mean hides it.** Over all balance hours
  (06:00–23:00 local) the median |error| is **10.2 W** and 49.7% of minutes are
  within ±10 W — but the *mean* is 199 W, because the midday hours (where the
  batteries cannot absorb the surplus, §4.1) drag it up. The distribution is
  bimodal in time, not noisy.
- **The loop is fast.** In the 2 h window, excursions beyond ±50 W last a median
  of **2 s**; beyond ±250 W, median 2 s, longest 65 s (3.3% of the time). Error
  autocorrelation is 0.82 at 1 s and 0.57 at 10 s — the residual is dominated by
  the meter's own ±30–50 W fluctuation, not by slow transients.
- **Discharge authority is near-unity.** Solis delivers 0.98–0.99 of the
  commanded power across 100–4000 W (see the table in §4.1). The fake-meter
  cascade works well in that direction.
- The anti-windup added in `0bf6957` (integral freeze + bounded integral) is
  doing its job: in the sampled window the central integral term sat at +558 W
  of the output, well inside its 1500 W bound.

The current dashboard metrics do not show this — see §4.5.

---

## 4. What the data says is actually limiting

### 4.1 The actuator set is asymmetric, saturating and SOC-dependent

Delivered/commanded battery power in balance mode, by commanded power bin
(7 days, 1-minute means):

| Commanded (W) | Solis n | Solis delivered/commanded | Solax n | Solax delivered/commanded |
| --- | --- | --- | --- | --- |
| −4000 … −1500 | 879 | **+0.06** | 737 | +0.20 |
| −1500 … −800 | 124 | +0.51 | 134 | +0.67 |
| −800 … −300 | 334 | +0.75 | 218 | +0.75 |
| −300 … −100 | 364 | +0.89 | 422 | +0.91 |
| +100 … +300 | 739 | +0.99 | 2781 | **+0.97** |
| +300 … +800 | 3229 | +0.98 | 2291 | **+0.31** |
| +800 … +1500 | 1380 | +0.98 | 99 | +0.73 |
| +1500 … +4000 | 132 | +0.93 | 18 | +0.35 |

Two things follow:

- **Charging authority collapses** (0.06 at −3.6 kW). Midday, the central loop
  asked the batteries to absorb a mean of **−1861 W**; they absorbed 179 W
  (Solis −32 W, Solax −147 W). The PV surplus went to the grid instead: **23.6
  kWh exported over 7 days** during 11:00–16:00 local (3.4 kWh/day ≈ 41p/day of
  export income), while the main bank sat at 90–95% SOC. The likely cause is
  BMS/inverter charge taper at high SOC, not the control law — at 93–95% SOC on
  a 580 Ah LiFePO4 bank the acceptance is naturally small.
  **Given the tariffs, this is the correct outcome, not a fault** (see §4.6):
  export pays 12p/kWh, and the alternative use of that energy is displacing
  off-peak import at 8.5p. Do not "fix" this by making the batteries absorb.
- **The two inverters are not interchangeable.** Solis holds 0.98 across the
  whole discharge range; Solax drops to 0.31 in the 300–800 W band. Solax is the
  much smaller unit — on 2026-09-21 it discharged only **0.94 kWh** across
  08:00–15:00Z (Solis: 2.49 kWh). Its `sensor.solax_percentage` meanwhile fell
  66% → 0%, which implies a battery of roughly **1.4 kWh** (or a badly calibrated
  percentage sensor; the two cannot both be right). Either way the fixed 2:1
  split asks ~1/3 of every demand from the smallest unit, which is why it is
  either empty or saturated much of the day.

What the control loop does about a saturated actuator is **wind up**: commanded
charge reached −1860 W mean at midday, −3491 W in the 14:00 hour, with the
worst minute at −5997 W, while delivering ~0. The bounded integral limits how
much of that is *integral* (25% of range = 1500 W of authority), so the rest is
proportional term chasing an error it cannot remove. Note that this windup is
wasted *even though the outcome is right* — the loop spends its full authority
fighting a battery that should not be charging, which is exactly what leaves it
unprepared at the mode switch (§4.3).

### 4.2 The derivative term is 41% of the output and does nothing

From the 100 Hz window. P and D are computed from the logged process variable
and the known gains; **I is the exact residual** `logged_output − P − D`, so
nothing here depends on a simulation or on the unlogged integral state:

| Term | mean | sd | tick-to-tick \|Δ\| mean | p99 |
| --- | --- | --- | --- | --- |
| P | −5.1 W | 77.8 W | 2.2 W | 41 W |
| I | +557.8 W | 175.7 W | 3.3 W | 66 W |
| **D** | 0.0 W | **154.0 W** | **73.2 W** | **889 W** |

- Covariance share of output variance: **P 9.4%, I 49.7%, D 40.9%** (sums to
  100% by construction, since the three terms add to the logged output).
- Validation that the model of the controller is right: the residual's drift,
  `(I_end − I_start)/ki = −1699 W·s`, matches the code's own
  `Σ error·dt = −1701 W·s` to **0.1%** — confirming the 10 ms tick, the sign
  convention, and that the logged trace is faithful.
- Why D is noise: `delta_time` is the 10 ms control tick, but the meter value
  only changes every ~80 ms. D therefore differentiates a zero-order-hold
  staircase, giving `kd·ΔE/0.01 = 15·ΔE` — a 15x gain on every fresh sample's
  noise (measured fresh-sample jumps: mean 20.2 W, p99 106 W).
- The result is an **impulse train at the meter's refresh rate**: the command
  swings ±90 W every ~80 ms, and the per-inverter targets reverse direction
  **~1900 times per minute** in the logged window.
- But it never reaches the plant: RMS amplitude by band (W):

  | Band | meter | needed (command) | Solis output | Solax output |
  | --- | --- | --- | --- | --- |
  | 0–0.5 Hz | 35.0 | 41.8 | 15.1 | 15.2 |
  | 12–25 Hz | 3.4 | **56.1** | 0.4 | 0.4 |
  | 25–50 Hz | 2.8 | **73.6** | 0.3 | 0.4 |

  The command carries 56–74 W RMS above 12 Hz; the measured battery outputs and
  the grid meter carry ≤3 W RMS there. The vendor loop filters it out.

So D is not a stability problem and not an energy problem — it is **wasted,
unmeasurable control action**, and it is what makes every dashboard metric
unreadable (§5). The honest caveat: the battery register is only polled at
200–500 ms, so a >10 Hz physical ripple would be averaged away in these
numbers; the grid meter (50 ms) would alias it. Adding a high-rate log of the
applied nudge and the inverter request rate would settle it — see §6.

### 4.3 Transients produce multi-kW single-tick commands

The mode switch at 04:29:00Z (05:29 BST), 100 Hz, is unambiguous:

| Time (UTC) | meter | needed_power | Solis target | Solis actual |
| --- | --- | --- | --- | --- |
| 04:28:59.995 | 1672.1 | 0.0 | −4000.0 | −1072 |
| **04:29:00.005** | 1672.1 | **6000.0** (at clamp) | **+4000.0** | −1072 |
| 04:29:00.016 | 1672.1 | 1550.6 | 1033.7 | −1072 |

- **6 kW of commanded power in a single 10 ms tick**, an **8 kW step** in the
  Solis target, then an immediate 4.4 kW step back. The cause is the derivative
  kick: `previous_error` is left over from before the charge window (the central
  PID is not called during charging) while `delta_time` is still 10 ms.
- Two minutes later, during the recovery swing, the output makes **±4 kW
  single-tick swings** (04:30:53.536: 1479.8 → −2597.5 → 1226.3 within 20 ms).
- The switch then oscillates: grid goes +1184 → +531 → +117 → −279 → −455 →
  +36 → +31 W before settling after ~2 minutes.

Also notable in the same data: during charge mode the commanded −4000 W /
−1000 W produced −1099 W / −27 W of actual charging (27% / 3% of target), i.e.
the charge window runs open-loop against an actuator that mostly ignores it.

### 4.4 The loop cannot see the disturbances it could predict

The relay already reads, at useful rates: Solis PV power (500 ms), Solis load
power (1 s), Solax power (200 ms), and lab solar power from Home Assistant
(1 s). None of it is used as feedforward; the only path from "the kettle just
turned on" to "the battery responds" is the integral slowly discovering the
error. Given the measured recovery is a few seconds, feedforward is worth
perhaps a couple of seconds of a ~500 W step — small in energy (the 2 h window's
large excursions total ~0.02 kWh) but it is also what lets you *lower* the
proportional/integral gains, which is what stops the windup in §4.1.

### 4.5 The reported metrics do not describe the plant

Live `/api/status` at the time of writing:

- Central: `overshoot: 691.9%`, `oscillation_count: 228`, `settling_time: 921.8`,
  `control_variability: 224.3`, `total_control_effort: 6.4e7`.
- Both inverter PIDs report `integral: -3.29e7` / `-9.38e6` **with `ki = 0.0`**.

`overshoot` is `(peak − setpoint)/setpoint` with a setpoint of 50 W and a
`peak_value` that never decays (`pid.rs:181`), so it measures the largest export
excursion divided by 50 W, not overshoot. `control_variability` and
`total_control_effort` are dominated by the D impulse train. And the inverter
integrals are dead state: `pid.rs:150` only clamps the integral `if ki != 0.0`,
so with `ki = 0` it accumulates forever and is then displayed as if it meant
something.

Tuning against this dashboard would be tuning against noise. Any decision about
control mechanism should start by fixing the metrics or ignoring them.

*(Also dead: the "if the PID goes insane, reset it" guard in `controller.rs:216`
— the bounded integral means the output cannot leave ±6000 W, let alone
±50 000 W.)*

### 4.6 What the control quality is actually worth, in money

Real tariffs: **import 8.5p/kWh 00:30–05:30, ~29.84p otherwise; export 12p/kWh at
all times.** Priced against the 7-day 1-minute data:

| Window | Imported | Exported | Net cost |
| --- | --- | --- | --- |
| Balance hours 06:00–23:00 local (125.6 h) | 1.39 kWh @ 29.84p | 27.97 kWh @ 12p | **−£2.94** (net income) |
| Go window 00:00–05:59 local (42.0 h) | 99.97 kWh @ 8.5p | — | +£29.79 |

- **The loop is not costing money.** If the grid had tracked −50 W *perfectly*
  through the balance hours it would have exported 6.28 kWh and earned £0.75 —
  i.e. the actual behaviour earns **£2.19 more** than perfect tracking, because
  the system correctly exports PV surplus at 12p rather than hoarding it. The
  50 W export target behaves as a floor, and at a 12p export rate that is the
  right way round.
- **The total financial exposure of tracking error is the peak-rate import the
  loop fails to avoid: 1.39 kWh/week ≈ £22/year.** That is the ceiling on any
  improvement to the regulator, and it is well below the effort of an MPC or an
  adaptive scheme.
- **The 12p-vs-8.5p spread means exporting beats storing by 3.5p/kWh.** Storing
  the midday surplus only wins if the displaced import would otherwise have been
  at the ~30p peak rate, and the bank is nearly full year-round (net daily SOC
  swing ~5% of 580 Ah), so it is not.
- Night charging (14.3 kWh/day at 8.5p instead of 29.84p) is doing the real
  work — roughly £3/day of avoided peak-rate import — and it is not
  control-limited.

Conclusion: at these tariffs there is **almost no money in the control loop**.
Changes are justified by robustness and hardware wear, not by energy cost. That
weakens the case for *any* control-mechanism swap considerably, and it removes
the "scheduler" rationale from §5 almost entirely — the existing rule (charge
cheap, hold a small export floor, let surplus go at 12p) is already the
profit-maximising one.

---

## 5. So — is a different mechanism better?

Judged per candidate, against what the measurements say actually limits the
system — and remembering that §4.6 caps the financial prize at ~£22/year plus
battery wear:

| Candidate | Addresses | Verdict |
| --- | --- | --- |
| **Feedforward + deadband + per-actuator anti-windup + slew limit** (still PID) | §4.1 windup, §4.3 steps, §4.4 disturbances | **Do this first.** Cheapest, largest fraction of the available headroom, no model needed. |
| **Authority/SOC-aware allocation** (replace the fixed 2:1 split) | §4.1 asymmetry, Solax cycling | **The one structural change with a defensible rationale** — not for energy (there is none) but to stop cycling the small Solax unit to empty for demand the large bank can cover for free. A tiny QP or a priority/water-filling split with per-inverter limits. |
| **ADRC (ESO-based single loop)** | §4.1 10x gain variation with direction/SOC, §4.2 D misuse | Legitimate swap if the regulator still misbehaves after the structural fixes: treats load/SOC/firmware gain drift as a lumped disturbance, no plant model, and it replaces D-on-a-staircase. Moderate effort; does **not** solve allocation or saturation. |
| **Gain scheduling / split-range** | §4.1 gain variation | Cheaper than ADRC, blunt but effective: separate gains for charge vs discharge, and per-inverter. |
| **Hysteresis / deadband controller** | §4.2 churn | Worth testing as the baseline: with ±20 W meter noise around a 50 W target, a ±25 W deadband holds the same energy performance (55% of samples are within ±25 W) at a fraction of the actuator activity. |
| **MPC** | constraints + day-ahead planning | **Not justified at these tariffs.** §4.6 shows the current rule (charge at 8.5p, hold a small export floor, sell surplus at 12p) is already profit-maximising; a planner would have to beat a 3.5p/kWh spread before battery degradation, which is typically 2–5p/kWh cycled. As a *regulator* it is overkill. |
| **RL / learned control** | — | Not justified. Actuator limits and SOC dominate; the data budget is fine but verifiability on a live installation is not. |
| **Smith predictor / dead-time compensation** | transport delay | The measured delay (poll + firmware) is already inside the loop's settling time; low value. |

The reasoning in one line: PID's weakness is that it is a *blind, single-channel*
regulator — it cannot know that one channel is saturated, that the other has 3x
the authority, or that the disturbance was measurable a second ago. Those are
exactly the three measured failures, and each has a targeted fix that is smaller
than swapping the algorithm.

**Where "a mechanism other than PID" would have won — and now doesn't.** The
natural candidate was the objective layer: replace the hard-coded setpoints with
a scheduler that picks SOC targets, charge amounts and export-vs-store decisions.
The tariff data (§4.6) removes that case. With export at 12p above the 8.5p Go
import price, the profit-maximising rule is the one the system already follows:
charge cheap overnight, keep a small export floor, let PV surplus go at 12p. A
planner would have to beat that, and the arithmetic leaves at most ~3.5p/kWh on
the table before battery degradation — i.e. negative once wear is counted. The
one genuine inefficiency left is not an energy question at all: the 2:1 split
cycles the ~1.4 kWh Solax battery to empty most days for demand the 580 Ah bank
could cover without cycling anything.

So the verdict is narrower than the question implies: the objective is sound, the
mechanism is sound, and what is left is *implementation* — a derivative term
doing nothing measurable, a mode switch that steps 6 kW in one tick, metrics that
cannot be trusted (§4.2, §4.3, §4.5), and an allocation that wears out a small
battery for no gain (§4.1).

---

## 6. How to decide empirically (recommended path)

With §4.6 capping the prize at ~£22/year plus battery wear, the honest
recommendation is: **fix the defects that are free to fix, and only build
instrumentation if you intend to touch the allocation or the loop structure.**
In that spirit, the cheapest items are (a) delete or properly filter the
derivative term, (b) reset/limit state across the charge↔balance switch, (c) fix
the metrics, and (d) make the 2:1 split authority-aware. Items (a)–(c) are
corrections, not experiments. The steps below are for anything beyond that.

1. **Instrument.** Log `last_nudge` per inverter and the inverter request
   interval to Influx (currently only in the live snapshot, so it cannot be
   analysed). Add a high-rate battery-power poll behind a flag if the >10 Hz
   question in §4.2 matters.
2. **Identify the plant.** Bounded PRBS/step test on the nudge (±150 W at
   0.05–0.1 Hz, mid-SOC, daytime, one inverter at a time), fit first-order +
   dead time **per inverter and per direction**, and repeat at high SOC to
   capture the charge taper. This is the missing piece for any model-based
   claim.
3. **Replay offline.** Feed the recorded disturbance traces (load, PV, grid)
   through the current controller and the candidates in §5, scored on grid
   error, actuator churn, and constraint violations. No live risk.
4. **Deploy in this order:** metrics fix → feedforward + deadband + slew limit +
   per-actuator anti-windup → authority-aware allocation → (only if still
   needed) ADRC or a planning layer.

Steps 1 and 3 alone answer the question "would X be better" with evidence rather
than opinion, and both are safe.

---

## 7. Reproducing this

```sh
# Export the windows used above from InfluxDB (bucket "Meter", measurement
# "relay"), pivoted so each field is a column. For example, 7 days at 1 minute:
#
#   from(bucket:"Meter") |> range(start:-7d)
#     |> filter(fn:(r)=>r._measurement=="relay")
#     |> aggregateWindow(every:1m, fn:mean, createEmpty:false)
#     |> pivot(rowKey:["_time"], columnKey:["_field"], valueColumn:"_value")

# tick-level behaviour, term attribution, and the 0.1% drift validation
python3 scripts/control_audit.py relay_raw_5m.csv --gains 0.9 0.3 0.15 --no-authority

# authority table, all hours vs balance hours only (BST = tz+1)
python3 scripts/control_audit.py relay_1m_7d.csv
python3 scripts/control_audit.py relay_1m_7d.csv --hours 6-23 --tz-offset 1
python3 scripts/control_audit.py relay_1m_7d.csv --hours 17-23 --tz-offset 1 --no-authority
```

`control_audit.py` reports tracking statistics, the P/I/D attribution with its
validation check, and the authority table by command bin. Numbers in this
document come from that script plus the recorded mode-switch window.

Note for future fetches: InfluxDB scans of the 6-field `relay` measurement are
slow — ~36 s for 7 days at 1-minute resolution, and multi-field aggregates over
30 days do not complete in a reasonable time. Query narrow windows or fewer
fields.
