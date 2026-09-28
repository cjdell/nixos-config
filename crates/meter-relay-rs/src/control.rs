//! The control law: one tick of the closed loop, with no I/O in it.
//!
//! `Controller` owns the sockets, the serial port, Home Assistant, Influx and
//! telemetry; everything that *decides* what to ask the inverters for lives
//! here, so it can be exercised against a simulated plant (see the tests at the
//! bottom) instead of only against the real one.
//!
//! The law is written against a *slice* of inverter states in priority order,
//! so it neither knows nor cares how many inverters the plant has.
//!
//! Tick order matters and is deliberate:
//!
//! 1. learn each inverter's authority from the *last* command and measurement;
//! 2. decide whether the reserve is needed, from the last tick's saturation;
//! 3. give the central PID the authority of the actuator set that is on line —
//!    this is the per-actuator anti-windup: the loop can never demand power the
//!    actuators cannot deliver, so it cannot sit pinned against a limit that
//!    does not exist;
//! 4. run the PID (deadband, bounded integral, live limits);
//! 5. split the demand by priority and slew-limit every target.

use crate::allocation::{Allocation, Allocator, AllocatorConfig, InverterState};
use crate::pid::{PidController, PidSnapshot};

/// Longest `dt` a single tick may assume (s): the loop runs at 10 ms, and a
/// stall must correct slowly rather than jump the integral by a second's worth
/// of error.
const MAX_STEP_SECONDS: f64 = 0.25;
/// Longest `dt` the authority estimates may be integrated over (s).
///
/// The probe that recovers a collapsed estimate is a *rate* in W/s, so it has
/// to be integrated over real time; `MAX_STEP_SECONDS` exists to protect the
/// PID's integral and applying it here instead scales the probe down by the
/// ratio of the loop's period to the clamp. A loop paced at 2 s per tick by its
/// own I/O — as the field one is — recovered its estimates at ~7 W/s where the
/// probe is 60 W/s (2026-09-26: a Go-window charge that took 17 minutes to reach
/// its rating, and a reserve left asking for 150 W all evening). This bound
/// still stops a long stall from slamming an estimate upwards, but it no longer
/// bites at any loop period the plant actually runs at.
const AUTHORITY_MAX_STEP_SECONDS: f64 = 2.0;
const MIN_STEP_SECONDS: f64 = 1e-3;

#[derive(Clone, Debug)]
pub struct ControlConfig {
    pub kp: f64,
    pub ki: f64,
    /// Derivative gain. Zero by default: the review measured the derivative
    /// contributing 41% of the output variance and nothing at all to the plant.
    pub kd: f64,
    /// Band inside which the grid error is ignored (W).
    pub deadband: f64,
    pub allocator: AllocatorConfig,
}

pub struct ControlLaw {
    pid: PidController,
    allocator: Allocator,
    meter_target: f64,
    last_time_ms: u64,
    last_error: f64,
    last_needed: f64,
    last_allocation: Allocation,
    charging: bool,
}

impl ControlLaw {
    pub fn new(cfg: ControlConfig, now: u64) -> Self {
        let allocator = Allocator::new(cfg.allocator);
        let limits = allocator.limits();
        let mut pid = PidController::with_limits(
            cfg.kp,
            cfg.ki,
            cfg.kd,
            limits.discharge,
            -limits.charge,
        );
        pid.set_deadband(cfg.deadband);
        pid.set_set_point(0.0);

        let last_allocation = allocator.idle_allocation();

        Self {
            pid,
            allocator,
            meter_target: 0.0,
            last_time_ms: now,
            last_error: 0.0,
            last_needed: 0.0,
            last_allocation,
            charging: false,
        }
    }

    pub fn set_meter_target(&mut self, target: f64) {
        self.meter_target = target;
    }

    pub fn allocator(&self) -> &Allocator {
        &self.allocator
    }

    pub fn allocation(&self) -> &Allocation {
        &self.last_allocation
    }

    pub fn pid_snapshot(&self) -> PidSnapshot {
        self.pid.snapshot()
    }

    /// Enter or leave the Octopus Go charging regime. The charge/balance
    /// transition is a plant regime change: the previous error and the
    /// integrator do not carry across it (leaving them in place is what
    /// produced the measured 6 kW single-tick command at 04:29:00).
    pub fn set_charging(&mut self, charging: bool) {
        if charging == self.charging {
            return;
        }
        self.charging = charging;
        self.pid.reset_dynamic_state();
        self.allocator.reset_regime();
        self.last_error = 0.0;
        self.last_needed = 0.0;
    }

    /// One balance-mode tick. `meter_power` is positive while importing, and
    /// `states` holds one entry per inverter in priority order (a state's `soc`
    /// is NaN when that device reports none).
    pub fn tick_balance(
        &mut self,
        meter_power: f64,
        states: &[InverterState],
        now: u64,
    ) -> Allocation {
        let (dt, probe_dt) = self.step_seconds(now);

        self.pid.set_set_point(self.meter_target);
        self.allocator.observe(states, now, probe_dt);

        // The reserve decision uses the previous tick's outcome: the PID's
        // authority has to be chosen before it runs.
        self.allocator
            .update_reserve(self.last_error, self.last_needed, now);

        let limits = self.allocator.limits();
        self.pid.set_output_limits(-limits.charge, limits.discharge);

        let needed = self.pid.calculate(-meter_power, dt);
        let allocation = self.allocator.split(needed, dt);

        self.last_error = self.pid.control_error();
        self.last_needed = needed;
        self.last_allocation = allocation.clone();
        allocation
    }

    /// One tick of the open-loop Go-window charge. The central PID does not
    /// run; each bank is charged at its configured rate, capped by the
    /// authority it has been observed to accept.
    pub fn tick_charge(&mut self, states: &[InverterState], now: u64) -> Allocation {
        let (dt, probe_dt) = self.step_seconds(now);
        self.allocator.observe(states, now, probe_dt);
        let allocation = self.allocator.split_charge(dt);
        self.last_allocation = allocation.clone();
        allocation
    }

    pub fn reset_metrics(&mut self) {
        self.pid.reset_metrics();
    }

    /// Returns `(dt, probe_dt)`: the step the PID and slew limiters use, and
    /// the step the authority estimates are integrated over. They differ
    /// because the first is deliberately clamped to keep one late tick out of
    /// the integral, and the second is a physical rate that must be integrated
    /// over real time — see `AUTHORITY_MAX_STEP_SECONDS`.
    fn step_seconds(&mut self, now: u64) -> (f64, f64) {
        let elapsed = now.saturating_sub(self.last_time_ms) as f64 / 1000.0;
        self.last_time_ms = now;
        (
            elapsed.clamp(MIN_STEP_SECONDS, MAX_STEP_SECONDS),
            elapsed.clamp(MIN_STEP_SECONDS, AUTHORITY_MAX_STEP_SECONDS),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation::{AllocatorConfig, InverterPolicy, ReserveState};

    const TICK_MS: u64 = 10;
    const TARGET: f64 = 50.0;
    /// State of charge the simulated reserve reports while it is healthy.
    const RESERVE_SOC: f64 = 60.0;

    /// One simulated battery: a first-order lag towards the power it is asked
    /// for, hard-limited by what it can actually give or accept.
    struct Battery {
        power: f64,
        discharge_cap: f64,
        charge_cap: f64,
        soc: f64,
    }

    impl Battery {
        fn new(discharge_cap: f64, charge_cap: f64, soc: f64) -> Self {
            Self {
                power: 0.0,
                discharge_cap,
                charge_cap,
                soc,
            }
        }

        fn step(&mut self, commanded: f64, dt: f64, tau: f64) -> f64 {
            let goal = commanded.clamp(-self.charge_cap, self.discharge_cap);
            let alpha = (dt / tau).min(1.0);
            self.power += alpha * (goal - self.power);
            self.power
        }
    }

    /// Deliberately simple plant: the grid is the house load minus PV minus
    /// every battery (positive = importing, matching the meter's convention).
    /// The real cascade puts the inverters' own zero-export loops inside that
    /// lag; the review measured the result as near-unity tracking in
    /// discharge, which this reproduces.
    ///
    /// The batteries are a `Vec`, not a pair: the point of the generalisation
    /// is that neither the law nor the plant changes shape when a third
    /// inverter arrives.
    struct Plant {
        batteries: Vec<Battery>,
        load: f64,
        pv: f64,
        tau: f64,
    }

    impl Plant {
        /// The two-inverter plant: a large main bank and a small reserve.
        fn new(load: f64, pv: f64) -> Self {
            Self {
                batteries: vec![
                    Battery::new(3_000.0, 3_000.0, 60.0),
                    Battery::new(1_500.0, 1_000.0, RESERVE_SOC),
                ],
                load,
                pv,
                tau: 0.3,
            }
        }

        fn power(&self, index: usize) -> f64 {
            self.batteries[index].power
        }

        fn step(&mut self, commanded: &[f64], dt: f64) {
            let tau = self.tau;
            for (battery, command) in self.batteries.iter_mut().zip(commanded) {
                battery.step(*command, dt, tau);
            }
        }

        fn grid(&self) -> f64 {
            self.load - self.pv - self.batteries.iter().map(|b| b.power).sum::<f64>()
        }

        fn states(&self, commanded: &[f64]) -> Vec<InverterState> {
            self.batteries
                .iter()
                .zip(commanded)
                .map(|(battery, command)| {
                    InverterState::new(*command, battery.power, true).with_soc(battery.soc)
                })
                .collect()
        }
    }

    /// Runs the loop against the plant, feeding each tick's targets back as the
    /// plant's commands, and returns the last allocation. `before_tick` runs at
    /// the start of each tick for scripted load changes.
    fn run(
        law: &mut ControlLaw,
        plant: &mut Plant,
        start: u64,
        ticks: u64,
        mut before_tick: impl FnMut(u64, &mut Plant),
    ) -> (u64, Allocation, Vec<f64>) {
        let mut now = start;
        let mut grid_trace = Vec::new();
        let mut last = law.allocation().clone();
        let mut commanded = last.targets();
        for _ in 0..ticks {
            before_tick(now, plant);
            plant.step(&commanded, TICK_MS as f64 / 1000.0);

            let states = plant.states(&commanded);
            last = law.tick_balance(plant.grid(), &states, now);
            grid_trace.push(plant.grid());
            commanded = last.targets();
            now += TICK_MS;
        }
        (now, last, grid_trace)
    }

    fn law(cfg: AllocatorConfig) -> ControlLaw {
        let mut law = ControlLaw::new(
            ControlConfig {
                kp: 0.9,
                ki: 0.3,
                kd: 0.0,
                deadband: 20.0,
                allocator: cfg,
            },
            0,
        );
        law.set_meter_target(TARGET);
        law
    }

    fn mean(values: &[f64]) -> f64 {
        if values.is_empty() {
            return 0.0;
        }
        values.iter().sum::<f64>() / values.len() as f64
    }

    #[test]
    fn reserve_stays_asleep_when_the_primary_covers_the_house() {
        let mut plant = Plant::new(1_500.0, 0.0);
        let mut law = law(AllocatorConfig::default());

        let (_, last, trace) = run(&mut law, &mut plant, 0, 6_000, |_, _| {});

        assert_eq!(last.target("solax"), 0.0, "the reserve must not be used for ordinary load");
        assert_eq!(last.state, ReserveState::PrimaryOnly);
        // The loop stops correcting inside the ±20 W deadband, so it settles
        // somewhere within one band of the target rather than exactly on it.
        let tail = &trace[trace.len() - 1_000..];
        assert!(
            (mean(tail) + TARGET).abs() < 35.0,
            "grid should hold the export target within the deadband, mean {} W",
            mean(tail)
        );
        assert!(plant.power(1).abs() < 1.0);
    }

    #[test]
    fn reserve_wakes_only_after_sustained_unmet_demand() {
        let mut cfg = AllocatorConfig::default();
        cfg.policy_mut("solis").max_discharge = 3_000.0;
        let mut plant = Plant::new(5_000.0, 0.0);
        let mut law = law(cfg.clone());

        // First, a load the primary can cover: the reserve must stay out.
        plant.load = 2_000.0;
        let (now, last, _) = run(&mut law, &mut plant, 0, 2_000, |_, _| {});
        assert_eq!(last.target("solax"), 0.0);
        assert_eq!(last.state, ReserveState::PrimaryOnly);

        // Now a load beyond the primary's authority. The reserve must engage,
        // and not before the confirmation delay has elapsed.
        let mut first_engaged_tick: Option<u64> = None;
        let mut tick = 0;
        let (now, last, trace) = run(&mut law, &mut plant, now, 4_000, |_, plant| {
            plant.load = 5_000.0;
            tick += 1;
            if first_engaged_tick.is_none() && plant.power(1) > 100.0 {
                first_engaged_tick = Some(tick);
            }
        });

        let engaged_after_ms = first_engaged_tick.expect("reserve should engage") * TICK_MS;
        assert!(
            engaged_after_ms >= cfg.wake_delay_ms,
            "reserve engaged after {engaged_after_ms} ms, before the {} ms confirmation",
            cfg.wake_delay_ms
        );
        assert_eq!(last.state, ReserveState::Reserve);
        assert!(
            (last.target("solax") - 1_500.0).abs() < 50.0,
            "reserve should carry the whole remainder, got {}",
            last.target("solax")
        );
        assert!((last.target("solis") - 3_000.0).abs() < 50.0);

        // The primary takes none of the blame for the shortfall: the reserve is
        // the one covering what it cannot, and the grid error is what is left.
        let tail = &trace[trace.len() - 500..];
        let leftover = mean(tail) + TARGET;
        assert!(leftover > 0.0, "the remaining import should be visible, got {leftover}");
        assert!(leftover < 700.0, "loop should get close to the target, got {leftover}");

        // The load drops back inside the primary's authority: the reserve is
        // released after the release delay and its target returns to zero.
        let (_, last, _) = run(&mut law, &mut plant, now, 6_000, |_, plant| {
            plant.load = 1_000.0;
        });
        assert_eq!(last.state, ReserveState::PrimaryOnly);
        assert_eq!(last.target("solax"), 0.0);
        assert!(plant.power(1).abs() < 50.0);
    }

    #[test]
    fn reserve_covers_a_shortfall_when_the_primary_is_empty() {
        // The main bank is spent even though its configured rating is high: the
        // authority estimate has to find that out and hand over.
        let mut plant = Plant::new(2_000.0, 0.0);
        plant.batteries[0].discharge_cap = 100.0;
        let mut law = law(AllocatorConfig::default());

        let (_, last, trace) = run(&mut law, &mut plant, 0, 6_000, |_, _| {});

        assert_eq!(last.state, ReserveState::Reserve);
        assert!(
            plant.power(1) > 1_000.0,
            "the reserve should be carrying real load, got {}",
            plant.power(1)
        );
        let tail = &trace[trace.len() - 1_000..];
        assert!(
            mean(tail) + TARGET < 900.0,
            "the reserve should close most of a 1.9 kW gap, left {} W",
            mean(tail) + TARGET
        );
    }

    /// The headline change: surplus the main bank cannot absorb goes into the
    /// reserve rather than to the grid, so the reserve has charge to give when
    /// a load spike needs it.
    #[test]
    fn a_full_main_bank_hands_the_surplus_to_the_reserve() {
        // 2 kW of PV surplus against a main bank that will only accept 200 W.
        // The old loop asked for a mean -1861 W and stayed pinned; the
        // authority estimate now caps the demand at what is really accepted,
        // and the remainder water-fills into the reserve.
        let mut plant = Plant::new(0.0, 2_000.0);
        plant.batteries[0].charge_cap = 200.0;
        let mut law = law(AllocatorConfig::default());

        let (_, last, trace) = run(&mut law, &mut plant, 0, 6_000, |_, _| {});

        let learned = last.by_id("solis").unwrap().charge_limit;
        assert!(
            learned < 500.0,
            "charge authority should follow the observed acceptance, got {learned}"
        );
        assert!(
            last.target("solis") > -600.0,
            "the loop must not keep asking for kilowatts the battery refuses, got {}",
            last.target("solis")
        );

        // The reserve picks up what the main bank cannot take.
        assert!(
            last.target("solax") < -800.0,
            "the reserve should absorb the remainder, got {}",
            last.target("solax")
        );
        assert!(last.absorbed > 800.0, "absorbed {}", last.absorbed);
        assert!(plant.power(1) < -500.0, "the reserve is really charging, {}", plant.power(1));

        // The surplus still ends up on the grid once both banks are full, but
        // it is much smaller than the 2 kW that would otherwise be exported.
        let tail = &trace[trace.len() - 1_000..];
        assert!(
            mean(tail) > -1_500.0,
            "the reserve should have cut the export, mean {}",
            mean(tail)
        );
    }

    /// Surplus absorption is bounded by the reserve's own ceiling, so it can
    /// never become a sink that hoards the whole day's export.
    #[test]
    fn the_reserve_is_not_charged_past_its_ceiling_by_surplus() {
        let mut plant = Plant::new(0.0, 2_000.0);
        plant.batteries[0].charge_cap = 200.0;
        plant.batteries[1].soc = 96.0;
        let mut law = law(AllocatorConfig::default());

        let (_, last, trace) = run(&mut law, &mut plant, 0, 6_000, |_, _| {});

        assert_eq!(last.target("solax"), 0.0, "a full reserve must be left alone");
        assert_eq!(last.absorbed, 0.0);
        // ... and the surplus it cannot take is exported, as before.
        let tail = &trace[trace.len() - 1_000..];
        assert!(
            mean(tail) < -1_200.0,
            "a full reserve means the surplus exports, mean {}",
            mean(tail)
        );
    }

    /// A day-like load profile in minutes: a base load, three sustained
    /// overloads beyond the primary's authority, and a train of 1 s spikes.
    fn scenario_load(t: f64) -> f64 {
        let minutes = t / 60.0;
        if (10.0..13.0).contains(&minutes) {
            return 3_500.0;
        }
        if (20.0..22.0).contains(&minutes) {
            return 2_500.0;
        }
        if (41.0..45.0).contains(&minutes) {
            return 4_500.0;
        }
        if minutes >= 47.0 && (minutes as u64).is_multiple_of(2) && t % 60.0 < 1.0 {
            return 3_000.0;
        }
        600.0
    }

    #[test]
    fn an_hour_of_house_load_wakes_the_reserve_only_for_real_overloads() {
        let mut cfg = AllocatorConfig::default();
        cfg.policy_mut("solis").max_discharge = 2_000.0;
        cfg.policy_mut("solax").max_discharge = 1_500.0;
        let mut law = law(cfg);

        // Primary 2 kW + reserve 1.5 kW exactly covers the 3.5 kW overload, so
        // the only import in the hour is the part of the 4.5 kW one that
        // nothing can cover.
        let mut plant = Plant::new(600.0, 0.0);
        plant.batteries[0].discharge_cap = 2_000.0;
        plant.batteries[1].discharge_cap = 1_500.0;

        let mut now = 0u64;
        let mut commanded = vec![0.0, 0.0];
        let mut engaged = false;
        let mut engagements = 0;
        let mut reserve_share_in_overload = Vec::new();
        let mut reserve_motion_under_base_load = 0.0f64;

        for tick in 0..360_000u64 {
            let t = tick as f64 * TICK_MS as f64 / 1000.0;
            plant.load = scenario_load(t);
            plant.step(&commanded, TICK_MS as f64 / 1000.0);

            let allocation = law.tick_balance(plant.grid(), &plant.states(&commanded), now);

            let reserve = allocation.state == ReserveState::Reserve;
            if reserve && !engaged {
                engagements += 1;
            }
            engaged = reserve;
            if (11.0..13.0).contains(&(t / 60.0)) {
                reserve_share_in_overload.push(allocation.target("solax"));
            }
            if (30.0..40.0).contains(&(t / 60.0)) {
                reserve_motion_under_base_load =
                    reserve_motion_under_base_load.max(plant.power(1).abs());
            }
            commanded = allocation.targets();
            now += TICK_MS;
        }

        // One engagement per genuine overload: the two 1 s spike groups at
        // minutes 47-59 are shorter than the wake delay and must not wake the
        // reserve at all.
        assert_eq!(
            engagements, 3,
            "expected one engagement per sustained overload, got {engagements}"
        );
        // The reserve carried exactly the part of the overload the primary could not.
        let share = mean(&reserve_share_in_overload[reserve_share_in_overload.len() - 1_000..]);
        assert!((share - 1_500.0).abs() < 60.0, "reserve share {share}");
        // Under base load the reserve battery never moves: this is the whole
        // point of the change.
        assert!(
            reserve_motion_under_base_load < 5.0,
            "reserve moved {reserve_motion_under_base_load} W under base load"
        );
    }

    /// Regression: a plant that follows its target with a few seconds of lag
    /// must not be mistaken for one that is refusing. The authority estimate's
    /// own upward probe creates a persistent command-vs-delivery gap on a slow
    /// plant; if that gap is judged as refusal the estimate collapses to what
    /// has been delivered, the loop is clamped to a fraction of the configured
    /// rating, and the grid sits well off target even though the battery has
    /// the power. This is the field failure: ~1 kW of import held for minutes
    /// while the main bank sat at ~1 kW of a 3.6 kW rating.
    #[test]
    fn a_slow_plant_is_not_mistaken_for_a_refusing_one() {
        let mut plant = Plant::new(2_500.0, 0.0);
        plant.tau = 3.0;
        plant.batteries[0].discharge_cap = 3_000.0;
        let mut law = law(AllocatorConfig::default());

        let (_, last, trace) = run(&mut law, &mut plant, 0, 120_000, |_, _| {});

        let tail = &trace[trace.len() - 2_000..];
        assert!(
            mean(tail) + TARGET < 300.0,
            "the loop must reach the target the plant can meet, left {} W (authority {})",
            mean(tail) + TARGET,
            last.by_id("solis").unwrap().discharge_limit
        );
        assert!(
            plant.power(0) > 2_000.0,
            "the main bank should be carrying the load, got {} W",
            plant.power(0)
        );
    }

    /// The authority probe is a *rate* in W/s, so it has to be integrated over
    /// real time. The loop's step is clamped to `MAX_STEP_SECONDS` so that one
    /// late tick cannot jump the PID's integral by a second's worth of error —
    /// but handing the probe that same clamped step scales it down by the ratio
    /// of the loop's period to the clamp. A loop whose own I/O paces it at 2 s
    /// per tick then recovers its estimates at ~7 W/s where the probe is
    /// 60 W/s: measured on 2026-09-26 as a Go-window charge that took 17
    /// minutes to reach its rating, and a reserve left asking for 150 W.
    #[test]
    fn a_slow_tick_does_not_slow_the_authority_probe() {
        // The loop in the field is paced by its own I/O, not by
        // CONTROL_INTERVAL, so drive this one at 2 s per tick.
        const SLOW_TICK_MS: u64 = 2_000;
        let mut law = law(AllocatorConfig::default());
        law.set_charging(true);
        let mut plant = Plant::new(800.0, 0.0);
        let mut now = 0u64;
        let mut commanded = vec![0.0, 0.0];

        // 1. Collapse the estimate: a bank that accepts 100 W of a 3.6 kW
        //    request, which is the state the field charge started from.
        plant.batteries[0].charge_cap = 100.0;
        for _ in 0..30 {
            now += SLOW_TICK_MS;
            plant.step(&commanded, SLOW_TICK_MS as f64 / 1000.0);
            let states = plant.states(&commanded);
            commanded = law.tick_charge(&states, now).targets();
        }
        let collapsed = commanded[0].abs();
        assert!(
            collapsed < 1_000.0,
            "estimate should have collapsed onto what the bank accepts, got {collapsed}"
        );

        // 2. The bank now takes what it is asked for, and the probe has to
        //    climb back to the rating at AUTHORITY_RELAX_W_PER_S. That rate is
        //    W/s, so the wall-clock time to recover must not depend on how many
        //    ticks the loop happened to take to cover it: at a 2 s tick the old
        //    clamped step recovered at ~7.5 W/s and needed ~7 minutes, while
        //    the same probe integrated over real time needs under a minute.
        plant.batteries[0].charge_cap = 3_600.0;
        let mut reached_at: Option<u64> = None;
        for _ in 0..300 {
            now += SLOW_TICK_MS;
            plant.step(&commanded, SLOW_TICK_MS as f64 / 1000.0);
            let states = plant.states(&commanded);
            commanded = law.tick_charge(&states, now).targets();
            if reached_at.is_none() && commanded[0].abs() > 3_500.0 {
                reached_at = Some(now);
            }
        }

        let reached = reached_at.expect("the probe should reach the 3.6 kW rating");
        assert!(
            reached <= 150_000,
            "reaching the rating took {reached} ms at a 2 s tick; the probe is a W/s rate and \
             must not be scaled by the loop's period"
        );
    }

    #[test]
    fn mode_switch_does_not_kick_the_output() {
        let mut cfg = AllocatorConfig::default();
        cfg.policy_mut("solis").charge_power = 4_000.0;
        let mut law = law(cfg);
        let mut plant = Plant::new(500.0, 0.0);

        // Charge for a while, as the Go window does.
        law.set_charging(true);
        let mut now = 0;
        let mut charging_target = 0.0;
        for _ in 0..3_000 {
            let states = vec![
                InverterState::new(charging_target, plant.power(0), true),
                InverterState::new(0.0, plant.power(1), true).with_soc(RESERVE_SOC),
            ];
            let allocation = law.tick_charge(&states, now);
            plant.step(&allocation.targets(), 0.01);
            charging_target = allocation.target("solis");
            now += TICK_MS;
        }
        assert!((charging_target + 3_000.0).abs() < 200.0, "should be charging hard");

        // Regime switch: the first balance tick must be a plain proportional
        // response, not a stale-integral or derivative kick.
        law.set_charging(false);
        let raw_error = 50.0 + plant.grid();
        let control_error = if raw_error > 20.0 {
            raw_error - 20.0
        } else if raw_error < -20.0 {
            raw_error + 20.0
        } else {
            0.0
        };
        let states = vec![
            InverterState::new(0.0, plant.power(0), true),
            InverterState::new(0.0, plant.power(1), true).with_soc(RESERVE_SOC),
        ];
        let allocation = law.tick_balance(plant.grid(), &states, now);
        let pid = law.pid_snapshot();
        let proportional = (0.9 * control_error).clamp(pid.min_output, pid.max_output);
        assert!(
            (pid.output - proportional).abs() < 1e-6,
            "first balance tick should be proportional only: output {} vs P {}",
            pid.output,
            proportional
        );
        assert_eq!(pid.integral, 0.0, "no stale integral across the regime change");
        // ... and the target cannot step, because the allocator slews it:
        // 4 kW/s at a 10 ms tick is 40 W.
        assert!(
            (allocation.target("solis") - charging_target).abs() <= 40.0 + 1e-9,
            "primary target moved {} W in one 10 ms tick",
            allocation.target("solis") - charging_target
        );
    }

    #[test]
    fn authority_of_the_engaged_set_is_what_the_loop_may_ask_for() {
        let mut law = law(AllocatorConfig::default());
        let states = vec![
            InverterState::new(0.0, 0.0, true),
            InverterState::new(0.0, 0.0, true).with_soc(RESERVE_SOC),
        ];

        let first = law.tick_balance(0.0, &states, 0);
        assert_eq!(
            first.total_discharge_limit, 3_600.0,
            "the primary alone while the reserve is out"
        );

        // A sustained shortfall brings the reserve on line, which widens the
        // loop's authority by exactly the reserve's share.
        let mut now = 0;
        for _ in 0..1_000 {
            now += TICK_MS;
            law.tick_balance(3_600.0, &states, now);
        }
        let engaged = law.tick_balance(3_600.0, &states, now);
        assert_eq!(engaged.state, ReserveState::Reserve);
        assert_eq!(engaged.total_discharge_limit, 3_600.0 + 1_500.0);
    }

    /// A third inverter needs no change to the law at all: the plant is a list
    /// of policies and the law is handed a matching list of states.
    #[test]
    fn a_third_battery_is_allocated_by_priority_without_touching_the_law() {
        let mut cfg = AllocatorConfig::default();
        cfg.policy_mut("solis").max_discharge = 1_000.0;
        cfg.policy_mut("solax").max_discharge = 600.0;
        cfg.inverters.push(InverterPolicy {
            max_discharge: 800.0,
            max_charge: 600.0,
            slew_w_per_s: 1_200.0,
            charge_power: 600.0,
            min_soc: Some(20.0),
            max_soc: Some(90.0),
            absorb_surplus: true,
            ..InverterPolicy::new("solax2", "Solax 2")
        });
        let mut law = law(cfg);

        let mut plant = Plant::new(2_400.0, 0.0);
        plant.batteries.push(Battery::new(800.0, 600.0, RESERVE_SOC));
        plant.batteries[0].discharge_cap = 1_000.0;
        plant.batteries[1].discharge_cap = 600.0;

        let (_, last, trace) = run(&mut law, &mut plant, 0, 8_000, |_, _| {});

        assert_eq!(last.inverters.len(), 3, "every inverter is allocated and published");
        assert!(last.inverters[0].primary);
        assert!(!last.inverters[2].primary);
        assert_eq!(last.state, ReserveState::Reserve);
        assert!((last.target("solis") - 1_000.0).abs() < 60.0);
        assert!(
            plant.power(1) > 400.0,
            "the second inverter should carry load, got {}",
            plant.power(1)
        );
        assert!(
            plant.power(2) > 400.0,
            "the third inverter should carry load, got {}",
            plant.power(2)
        );
        let tail = &trace[trace.len() - 1_000..];
        assert!(
            mean(tail) + TARGET < 300.0,
            "the plant should hold the target, left {} W",
            mean(tail) + TARGET
        );
    }
}
