//! PID controller with bounded anti-windup, an error deadband, derivative on
//! measurement and online performance metrics.
//!
//! The control review (`CONTROL-REVIEW.md`) measured three defects in the
//! original loop, all of which are addressed here:
//!
//! * **D on a staircase.** The output is differentiated, but the process value
//!   only refreshes every ~80 ms while the loop runs at 10 ms, so `kd·ΔE/dt`
//!   became a 15x-gain impulse train on sample noise (41% of the output
//!   variance, none of it reaching the plant). The derivative is now taken on
//!   the *measurement* (so a setpoint step cannot kick it) and low-pass
//!   filtered; `kd = 0` by default, because the measurement showed it bought
//!   nothing.
//! * **Metrics that describe noise.** Histories of every 10 ms sample are gone:
//!   metrics are running sums, the "overshoot against a 50 W target" that never
//!   decayed is replaced by peak error and time-in-band, and control effort is
//!   integrated into actual actuator energy instead of a sum over samples.
//! * **Dead integral state.** With `ki = 0` the integrator used to accumulate
//!   forever and then be displayed as if it meant something. It is now pinned
//!   at zero when it is not in the loop.

use serde::Serialize;

/// Maximum share of the output range that the integral term (Ki * I) may
/// occupy.
///
/// This is 1.0, i.e. the integral may carry the whole live authority. That is
/// deliberate: the authority it is scaled against is now the *learned* one
/// (see `allocation.rs`), and the anti-windup job is done by conditional
/// integration against that live limit, not by an arbitrary fraction of it.
/// The previous 0.25 of a fixed 6 kW range left the loop unable to hold any
/// steady demand above 1.5 kW without a proportional error - and a proportional
/// error of a few hundred watts is exactly what the reserve's wake test has to
/// distinguish from a genuine shortfall.
const INTEGRAL_RANGE_FRACTION: f64 = 1.0;

/// Default band around the setpoint inside which the error is treated as zero
/// (W). The grid meter itself fluctuates by ±30-50 W, so without a deadband the
/// loop spends its time chasing measurement noise.
const DEFAULT_SETTLE_TOLERANCE: f64 = 25.0;

/// Minimum spacing between counted target crossings (s). Meter noise changes
/// sign every few samples; a crossing only counts as an oscillation once the
/// value has stayed on the new side for this long.
const CROSSING_DWELL_S: f64 = 2.0;

/// Time constant of the `slow_error` mean (s).
const SLOW_ERROR_TAU_S: f64 = 10.0;

/// Default time constant of the derivative filter (s). The meter refreshes
/// every ~80 ms, so filtering below that is pointless; this is here to make a
/// non-zero `kd` safe rather than to invite one.
const DEFAULT_DERIVATIVE_TAU_S: f64 = 2.0;

#[derive(Clone, Debug, Default, Serialize)]
pub struct PidMetrics {
    /// Mean |error| over the current window (W).
    pub mean_absolute_error: f64,
    /// Root-mean-square error over the current window (W).
    pub root_mean_square_error: f64,
    /// Largest |error| seen in the current window (W).
    pub peak_error: f64,
    /// Share of samples inside the tolerance band (%).
    pub in_band_percent: f64,
    /// Target crossings that survived the dwell filter, since the last reset.
    pub oscillation_count: u32,
    /// ∫|output|dt since the last reset (kWh) — the actual work commanded.
    pub actuator_energy_kwh: f64,
    /// RMS of the output change between ticks (W) — how choppy the command is.
    pub output_roughness: f64,
    /// Most recent error (W).
    pub current_error: f64,
    /// Slow (10 s) mean of the error (W) — the bias the integral is trimming.
    pub slow_error: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct PidSnapshot {
    pub set_point: f64,
    /// Most recent *true* error, before the deadband (W).
    pub error: f64,
    pub output: f64,
    pub integral: f64,
    pub kp: f64,
    pub ki: f64,
    pub kd: f64,
    /// Live authority limits: for the central loop these are the allocator's
    /// learned total capability, not a fixed clamp.
    pub min_output: f64,
    pub max_output: f64,
    /// Size of the band inside which the error is ignored (W).
    pub deadband: f64,
    /// True when the clamped output is not the raw PID output, i.e. the
    /// controller is asking for more (or less) than the limits allow.
    pub saturated: bool,
    pub metrics: PidMetrics,
}

/// PID controller with the performance tracking from the TypeScript version,
/// reworked so the tracking describes the plant rather than the noise.
pub struct PidController {
    kp: f64,
    ki: f64,
    kd: f64,
    max_output: f64,
    min_output: f64,
    deadband: f64,
    derivative_tau: f64,

    /// Deadbanded error actually used by the control law.
    previous_error: f64,
    /// True error against the setpoint, as reported to the operator.
    last_error: f64,
    previous_measurement: Option<f64>,
    derivative: f64,
    integral: f64,
    set_point: f64,
    last_output: f64,
    saturated: bool,

    // --- Online metrics: running sums, so a 100 Hz loop keeps no history ---
    samples: u64,
    sum_abs_error: f64,
    sum_sq_error: f64,
    peak_abs_error: f64,
    in_band_samples: u64,
    settle_tolerance: f64,
    effort_ws: f64,
    sum_output_delta: f64,
    sum_output_delta_sq: f64,
    output_delta_count: u64,
    slow_error: f64,
    elapsed_time: f64,
    last_side: Option<bool>,
    last_crossing_time: f64,
    crossings: u32,
}

impl PidController {
    pub fn new(kp: f64, ki: f64, kd: f64, max_output: f64) -> Self {
        Self::with_limits(kp, ki, kd, max_output, -max_output)
    }

    pub fn with_limits(kp: f64, ki: f64, kd: f64, max_output: f64, min_output: f64) -> Self {
        Self {
            kp,
            ki,
            kd,
            max_output,
            min_output,
            deadband: 0.0,
            derivative_tau: DEFAULT_DERIVATIVE_TAU_S,
            previous_error: 0.0,
            last_error: 0.0,
            previous_measurement: None,
            derivative: 0.0,
            integral: 0.0,
            set_point: 0.0,
            last_output: 0.0,
            saturated: false,
            samples: 0,
            sum_abs_error: 0.0,
            sum_sq_error: 0.0,
            peak_abs_error: 0.0,
            in_band_samples: 0,
            settle_tolerance: DEFAULT_SETTLE_TOLERANCE,
            effort_ws: 0.0,
            sum_output_delta: 0.0,
            sum_output_delta_sq: 0.0,
            output_delta_count: 0,
            slow_error: 0.0,
            elapsed_time: 0.0,
            last_side: None,
            last_crossing_time: 0.0,
            crossings: 0,
        }
    }

    /// Errors inside `±deadband` are ignored by the control law (the true error
    /// is still reported and measured).
    pub fn set_deadband(&mut self, deadband: f64) {
        self.deadband = deadband.abs();
    }

    /// Replaces the output clamp. The central loop calls this every tick with
    /// the allocator's learned authority, so the integrator can never wind up
    /// against authority the actuators do not have.
    pub fn set_output_limits(&mut self, min_output: f64, max_output: f64) {
        self.min_output = min_output;
        self.max_output = max_output;
    }

    /// The deadbanded error the control law acted on last tick.
    pub fn control_error(&self) -> f64 {
        self.previous_error
    }

    pub fn set_set_point(&mut self, set_point: f64) {
        self.set_point = set_point;
    }

    pub fn set_point(&self) -> f64 {
        self.set_point
    }

    pub fn calculate(&mut self, current_value: f64, delta_time: f64) -> f64 {
        let delta_time = if delta_time.is_finite() && delta_time > 0.0 {
            delta_time
        } else {
            1e-3
        };

        let error = self.set_point - current_value;
        let control_error = deadbanded(error, self.deadband);

        // Derivative on measurement, low-pass filtered. Differentiating the
        // error instead would turn every setpoint step into a kick; the process
        // value is what the loop actually needs to damp.
        let derivative = if self.kd != 0.0 {
            let raw = match self.previous_measurement {
                Some(previous) => -(current_value - previous) / delta_time,
                None => 0.0,
            };
            let alpha = (delta_time / self.derivative_tau).min(1.0);
            self.derivative += alpha * (raw - self.derivative);
            self.derivative
        } else {
            0.0
        };
        self.previous_measurement = Some(current_value);

        let unclamped_output =
            (self.kp * control_error) + (self.ki * self.integral) + (self.kd * derivative);

        let output_clamped = unclamped_output.clamp(self.min_output, self.max_output);
        self.saturated = unclamped_output != output_clamped;

        // Anti-windup, in two layers.
        //
        // 1. Conditional integration ("freeze"): while the output is clamped
        //    and the error pushes it further into that clamp — the plant
        //    cannot track the demand, e.g. an empty battery — the integrator
        //    holds still instead of winding up. It resumes as soon as the
        //    error relaxes or the output leaves the limit.
        //
        // 2. Bounded integral: the integral is clamped so its term alone
        //    (Ki * I) can never use more than INTEGRAL_RANGE_FRACTION of the
        //    output range, whatever the history. That is what stops a long,
        //    unserviceable error from leaving the output pinned at the limit
        //    long after the plant could have recovered.
        let pushing_into_clamp = if output_clamped < unclamped_output {
            // clamped at max_output: a positive error would push it higher
            control_error > 0.0
        } else if output_clamped > unclamped_output {
            // clamped at min_output: a negative error would push it lower
            control_error < 0.0
        } else {
            false
        };

        if self.ki != 0.0 {
            if !pushing_into_clamp {
                self.integral += control_error * delta_time;
            }

            let lo = self.min_output * INTEGRAL_RANGE_FRACTION / self.ki;
            let hi = self.max_output * INTEGRAL_RANGE_FRACTION / self.ki;
            self.integral = if lo <= hi {
                self.integral.clamp(lo, hi)
            } else {
                self.integral.clamp(hi, lo)
            };
        } else {
            // No integral action: hold no integral state at all, so the
            // dashboard cannot show dead numbers as if they meant something.
            self.integral = 0.0;
        }

        self.previous_error = control_error;
        self.last_error = error;
        self.update_metrics(error, output_clamped, delta_time);
        self.last_output = output_clamped;

        output_clamped
    }

    fn update_metrics(&mut self, error: f64, output: f64, delta_time: f64) {
        self.elapsed_time += delta_time;

        let abs_error = error.abs();
        if self.samples > 0 {
            let delta = (output - self.last_output).abs();
            self.sum_output_delta += delta;
            self.sum_output_delta_sq += delta * delta;
            self.output_delta_count += 1;
        }

        self.samples += 1;
        self.sum_abs_error += abs_error;
        self.sum_sq_error += error * error;
        self.peak_abs_error = self.peak_abs_error.max(abs_error);
        if abs_error <= self.settle_tolerance {
            self.in_band_samples += 1;
        }
        self.effort_ws += output.abs() * delta_time;

        let alpha = (delta_time / SLOW_ERROR_TAU_S).min(1.0);
        self.slow_error += alpha * (error - self.slow_error);

        if abs_error > self.settle_tolerance {
            let side = error > 0.0;
            if let Some(previous_side) = self.last_side {
                if previous_side != side
                    && self.elapsed_time - self.last_crossing_time >= CROSSING_DWELL_S
                {
                    self.crossings += 1;
                    self.last_crossing_time = self.elapsed_time;
                }
            }
            self.last_side = Some(side);
        }
    }

    pub fn get_metrics(&self) -> PidMetrics {
        if self.samples == 0 {
            return PidMetrics::default();
        }

        let n = self.samples as f64;
        let roughness = if self.output_delta_count == 0 {
            0.0
        } else {
            (self.sum_output_delta_sq / self.output_delta_count as f64).sqrt()
        };

        PidMetrics {
            mean_absolute_error: self.sum_abs_error / n,
            root_mean_square_error: (self.sum_sq_error / n).sqrt(),
            peak_error: self.peak_abs_error,
            in_band_percent: self.in_band_samples as f64 / n * 100.0,
            oscillation_count: self.crossings,
            actuator_energy_kwh: self.effort_ws / 3.6e6,
            output_roughness: roughness,
            current_error: self.last_error,
            slow_error: self.slow_error,
        }
    }

    pub fn snapshot(&self) -> PidSnapshot {
        PidSnapshot {
            set_point: self.set_point,
            error: self.last_error,
            output: self.last_output,
            integral: self.integral,
            kp: self.kp,
            ki: self.ki,
            kd: self.kd,
            min_output: self.min_output,
            max_output: self.max_output,
            deadband: self.deadband,
            saturated: self.saturated,
            metrics: self.get_metrics(),
        }
    }

    pub fn reset_metrics(&mut self) {
        self.samples = 0;
        self.sum_abs_error = 0.0;
        self.sum_sq_error = 0.0;
        self.peak_abs_error = 0.0;
        self.in_band_samples = 0;
        self.effort_ws = 0.0;
        self.sum_output_delta = 0.0;
        self.sum_output_delta_sq = 0.0;
        self.output_delta_count = 0;
        self.slow_error = 0.0;
        self.elapsed_time = 0.0;
        self.last_side = None;
        self.last_crossing_time = 0.0;
        self.crossings = 0;
    }

    /// Clears everything the controller carries *between* ticks, keeping its
    /// tuning and its metrics. Called when the plant's regime changes (the
    /// charge/balance switch): the previous error is stale by then, and using
    /// it produced a 6 kW single-tick command in the measured data.
    pub fn reset_dynamic_state(&mut self) {
        self.previous_error = 0.0;
        self.last_error = 0.0;
        self.previous_measurement = None;
        self.derivative = 0.0;
        self.integral = 0.0;
        self.saturated = false;
    }

}

/// Subtracts the deadband from the error, preserving its sign, so the response
/// stays continuous just outside the band instead of jumping.
fn deadbanded(error: f64, deadband: f64) -> f64 {
    if deadband <= 0.0 {
        return error;
    }
    if error > deadband {
        error - deadband
    } else if error < -deadband {
        error + deadband
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proportional_output() {
        let mut pid = PidController::new(2.0, 0.0, 0.0, 100.0);
        pid.set_set_point(50.0);
        // error = 50 - 0 = 50 -> 2 * 50 = 100
        assert!((pid.calculate(0.0, 1.0) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn clamps_output() {
        let mut pid = PidController::new(10.0, 0.0, 0.0, 100.0);
        pid.set_set_point(50.0);
        assert!((pid.calculate(0.0, 1.0) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn zero_ki_does_not_produce_nan_when_saturated() {
        let mut pid = PidController::new(2.0, 0.0, 0.0, 10.0);
        pid.set_set_point(1000.0);
        let out = pid.calculate(0.0, 1.0);
        assert!(out.is_finite());
    }

    #[test]
    fn zero_ki_keeps_no_integral_state() {
        // The old inverter PIDs reported an integral of -3.3e7 W·s while
        // Ki was zero: state that accumulated forever and was then displayed
        // as if it meant something.
        let mut pid = PidController::new(0.3, 0.0, 0.0, 3600.0);
        pid.set_set_point(-164.0);
        for _ in 0..10_000 {
            pid.calculate(-96.0, 0.01);
        }
        assert_eq!(pid.snapshot().integral, 0.0);
    }

    #[test]
    fn integral_freezes_while_error_pushes_into_clamp() {
        // Gains where the P term alone saturates the output: kp=2.0, error
        // 3050 -> 6100 W > 6000 W limit. The plant cannot track (empty
        // battery), so the integrator must not wind up at all.
        let mut pid = PidController::new(2.0, 0.3, 0.0, 6_000.0);
        pid.set_set_point(50.0);

        let mut out = 0.0;
        for _ in 0..1_000 {
            // Meter importing 3000 W -> current_value = -3000, error = 3050.
            out = pid.calculate(-3_000.0, 0.01);
        }

        assert!((out - 6_000.0).abs() < 1e-9, "output should stay at the limit");
        assert!(pid.snapshot().saturated);
        assert_eq!(pid.snapshot().integral, 0.0, "integral must stay frozen at 0");
    }

    #[test]
    fn integral_can_carry_a_steady_demand_inside_the_live_authority() {
        // A plant that delivers what it is asked for, with a small lag. The
        // loop must reach the target with no proportional error left, whatever
        // the steady demand, as long as it is inside the authority. With the
        // old bound (25% of a fixed 6 kW range) this settled at a ~1.7 kW error.
        let mut pid = PidController::new(0.9, 0.3, 0.0, 3_600.0);
        pid.set_set_point(50.0);

        // 2.4 kW of house load against a 50 W export target: the battery has to
        // deliver 2.45 kW.
        let mut delivered = 0.0;
        for _ in 0..60_000 {
            let command = pid.calculate(-(2_400.0 - delivered), 0.01);
            delivered += 0.03 * (command - delivered);
        }

        let snap = pid.snapshot();
        assert!((snap.output - 2_450.0).abs() < 25.0, "output {}", snap.output);
        assert!(
            snap.error.abs() < 30.0,
            "a 2.4 kW steady demand must be met without a proportional error, got {} W",
            snap.error
        );
        assert!(!snap.saturated);
    }

    #[test]
    fn integral_unwinds_when_error_relaxes() {
        let mut pid = PidController::new(0.0, 0.3, 0.0, 6_000.0);
        pid.set_set_point(50.0);

        // 4 s of a +200 W error: I = 800, well inside the bound.
        for _ in 0..400 {
            pid.calculate(-150.0, 0.01); // error = 200
        }
        assert!((pid.snapshot().integral - 800.0).abs() < 1e-6);

        // Demand is now met and then some: error = -100. The integral must
        // unwind at |error| per second.
        for _ in 0..200 {
            pid.calculate(150.0, 0.01); // error = -100
        }
        assert!((pid.snapshot().integral - 600.0).abs() < 1e-6);
    }

    #[test]
    fn a_sustained_error_the_actuators_cannot_remove_winds_no_further_than_the_limit() {
        // Empty battery: the loop asks for 2 kW off a 3.6 kW authority it will
        // never get. The output pins at the live limit and the integral freezes
        // there — it cannot accumulate authority the actuators do not have.
        let mut pid = PidController::new(0.9, 0.3, 0.0, 3_600.0);
        pid.set_set_point(50.0);
        for _ in 0..60_000 {
            pid.calculate(-2_000.0, 0.01); // error = 2050, current_value = -2000
        }
        let snap = pid.snapshot();
        assert!((snap.output - 3_600.0).abs() < 1e-9, "output {}", snap.output);
        assert!(snap.saturated);
        assert!(
            (snap.ki * snap.integral) <= 3_600.0 + 1e-6,
            "integral term {} exceeds the live authority",
            snap.ki * snap.integral
        );
    }

    #[test]
    fn saturated_flag_tracks_clamping() {
        let mut pid = PidController::new(10.0, 0.0, 0.0, 100.0);
        pid.set_set_point(50.0);

        pid.calculate(0.0, 1.0); // output clamped to 100
        assert!(pid.snapshot().saturated);

        pid.reset_dynamic_state();
        assert!(!pid.snapshot().saturated);

        pid.calculate(50.0, 1.0); // error 0 -> no clamping
        assert!(!pid.snapshot().saturated);
    }

    #[test]
    fn dynamic_limits_bound_the_output_and_the_integral() {
        let mut pid = PidController::new(0.9, 0.3, 0.0, 6_000.0);
        pid.set_set_point(50.0);

        // The allocator learns that the actuators can only take 250 W right
        // now (e.g. a full battery refusing charge).
        pid.set_output_limits(-250.0, 1_500.0);
        for _ in 0..20_000 {
            pid.calculate(3_000.0, 0.01); // error = 50 - 3000 = -2950
        }

        let snap = pid.snapshot();
        assert!((snap.output + 250.0).abs() < 1e-9, "output must respect the live limit");
        // The plant is refusing, so the output is pinned and the integral
        // freezes instead of winding up against authority that is not there.
        assert_eq!(snap.integral, 0.0);
        assert_eq!(snap.min_output, -250.0);
        assert_eq!(snap.max_output, 1_500.0);
        assert!(snap.saturated);

        // When the battery starts accepting again, the authority widens and
        // the loop is free to ask for more.
        pid.set_output_limits(-3_600.0, 3_600.0);
        let out = pid.calculate(3_000.0, 0.01);
        assert!(out < -250.0, "widened authority should be used, got {out}");
    }

    #[test]
    fn deadband_ignores_small_errors_but_reports_them() {
        let mut pid = PidController::new(0.9, 0.3, 0.0, 6_000.0);
        pid.set_set_point(50.0);
        pid.set_deadband(20.0);

        // error = 15 W: inside the band, so the loop must not react at all.
        let out = pid.calculate(35.0, 0.01);
        assert_eq!(out, 0.0);
        assert_eq!(pid.snapshot().integral, 0.0);
        // ... but the true error is still what the operator sees.
        assert!((pid.snapshot().error - 15.0).abs() < 1e-9);
        assert!((pid.snapshot().metrics.peak_error - 15.0).abs() < 1e-9);

        // error = 60 W: outside the band, so it acts on 60 - 20 = 40 W.
        let out = pid.calculate(-10.0, 0.01);
        assert!((out - 36.0).abs() < 1e-9);
    }

    #[test]
    fn deadband_stops_the_loop_chasing_meter_noise() {
        let mut pid = PidController::new(0.9, 0.3, 0.0, 6_000.0);
        pid.set_set_point(50.0);
        pid.set_deadband(20.0);

        // A meter sitting inside the band, wobbling sample to sample.
        let mut outputs = Vec::new();
        for i in 0..500 {
            let meter = -50.0 + if i % 2 == 0 { 12.0 } else { -12.0 };
            outputs.push(pid.calculate(-meter, 0.01));
        }
        assert!(outputs.iter().all(|o| *o == 0.0), "output must stay put inside the band");
    }

    #[test]
    fn derivative_is_taken_on_the_measurement_not_the_setpoint() {
        // A setpoint step must not kick the derivative (the 04:29:00 mode
        // switch produced a 6 kW single-tick command this way).
        let mut pid = PidController::new(0.0, 0.0, 0.15, 6_000.0);
        pid.set_set_point(50.0);
        for _ in 0..100 {
            pid.calculate(-100.0, 0.01);
        }
        pid.set_set_point(-4_000.0); // charge -> balance style step
        let kick = pid.calculate(-100.0, 0.01);
        assert!(kick.abs() < 1e-6, "setpoint step produced a {kick} W derivative kick");
    }

    #[test]
    fn filtered_derivative_tracks_measurement_motion() {
        let mut pid = PidController::new(0.0, 0.0, 1.0, 100_000.0);
        pid.set_set_point(0.0);
        pid.set_deadband(0.0);
        // The measurement falls 100 W/s, so the error rises at 100 W/s and the
        // (filtered) derivative term must approach +100.
        let mut value = 0.0;
        let mut out = 0.0;
        for _ in 0..600 {
            value -= 1.0;
            out = pid.calculate(value, 0.01);
        }
        assert!((out - 100.0).abs() < 5.0, "filtered derivative should approach +100, got {out}");
    }

    #[test]
    fn reset_dynamic_state_drops_stale_error_and_integral() {
        let mut pid = PidController::new(0.9, 0.3, 0.0, 6_000.0);
        pid.set_set_point(50.0);
        for _ in 0..1_000 {
            pid.calculate(-3_000.0, 0.01);
        }
        assert!(pid.snapshot().integral.abs() > 1.0);
        let metrics_before = pid.snapshot().metrics.mean_absolute_error;

        pid.reset_dynamic_state();
        let snap = pid.snapshot();
        assert_eq!(snap.integral, 0.0);
        assert!(!snap.saturated);
        // The record of what was last commanded survives (it really was
        // applied), but the next calculation starts from a clean slate: pure
        // proportional response, no stale integral.
        assert!((pid.calculate(-3_000.0, 0.01) - (0.9 * 3_050.0)).abs() < 1e-6);
        // Metrics are a rolling window; a regime change does not erase them.
        assert_eq!(snap.metrics.mean_absolute_error, metrics_before);
    }

    #[test]
    fn metrics_describe_the_window() {
        let mut pid = PidController::new(1.0, 0.0, 0.0, 100.0);
        pid.set_set_point(50.0);
        // 200 samples 10 W off target (in band), then 200 samples 100 W off.
        for _ in 0..200 {
            pid.calculate(40.0, 0.01);
        }
        for _ in 0..200 {
            pid.calculate(-50.0, 0.01); // error = 100
        }

        let m = pid.snapshot().metrics;
        assert!((m.mean_absolute_error - 55.0).abs() < 1e-6);
        assert!((m.peak_error - 100.0).abs() < 1e-6);
        assert!((m.in_band_percent - 50.0).abs() < 1e-6);
        assert_eq!(m.oscillation_count, 0, "one dwell-filtered crossing counts, not two sides");
        // Output is 10 W for the first half and 100 W for the second, so the
        // commanded energy is 0.01 s * (200*10 + 200*100) W = 220 W·s.
        assert!((m.actuator_energy_kwh - 220.0 / 3.6e6).abs() < 1e-12);
    }

    #[test]
    fn oscillation_count_survives_the_dwell_filter() {
        let mut pid = PidController::new(1.0, 0.0, 0.0, 100.0);
        pid.set_set_point(50.0);

        // A 3 s square wave well outside the band: 12 s -> 3 counted crossings
        // (the first transition has no previous side to count against).
        for i in 0..1_200 {
            let value = if i % 300 < 150 { 100.0 } else { 0.0 };
            pid.calculate(value, 0.01); // current_value 100 -> error -50; 0 -> error +50
        }
        let m = pid.snapshot().metrics;
        assert_eq!(m.oscillation_count, 3, "crossings once per second, minus the first");

        // Meter noise inside the band must not count at all.
        let mut noisy = PidController::new(1.0, 0.0, 0.0, 100.0);
        noisy.set_set_point(50.0);
        for i in 0..1_000 {
            noisy.calculate(if i % 2 == 0 { 30.0 } else { 70.0 }, 0.01);
        }
        assert_eq!(noisy.snapshot().metrics.oscillation_count, 0);
    }
}
