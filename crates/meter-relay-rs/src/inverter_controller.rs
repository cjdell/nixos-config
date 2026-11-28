use std::sync::{Arc, Mutex};

use crate::inverters::Inverter;
use crate::meter::{self, Meter};
use crate::parser::ModbusRequest;
use crate::pid::{PidController, PidSnapshot};
use crate::transport::RequestHandler;
use crate::util::now_ms;

/// Smoothing for the reported meter-request interval: the inverters' request
/// cadence is what sets how often a new phantom reading reaches them.
const INTERVAL_SMOOTHING: f64 = 0.2;

/// Per-inverter controller: rewrites the active power register the inverter
/// reads from the shared meter using its own PID, and tracks the PID target
/// set by the allocator.
pub struct InverterController {
    name: String,
    pid: Arc<Mutex<PidController>>,
    inverter: Arc<dyn Inverter>,
    meter: Arc<Meter>,
    reverse: bool,
    /// The meter *dialect* this inverter's line speaks: which register
    /// positions carry grid power (the nudge rides on them) and current.
    dialect: &'static meter::MeterDialect,
    last_time: Arc<Mutex<u64>>,
    last_nudge: Arc<Mutex<f64>>,
    request_interval_ms: Arc<Mutex<f64>>,
}

impl InverterController {
    pub fn new(
        name: impl Into<String>,
        pid: PidController,
        inverter: Arc<dyn Inverter>,
        meter: Arc<Meter>,
        reverse: bool,
        dialect: &'static meter::MeterDialect,
    ) -> Arc<Self> {
        Arc::new(Self {
            name: name.into(),
            pid: Arc::new(Mutex::new(pid)),
            inverter,
            meter,
            reverse,
            dialect,
            last_time: Arc::new(Mutex::new(now_ms())),
            last_nudge: Arc::new(Mutex::new(0.0)),
            request_interval_ms: Arc::new(Mutex::new(0.0)),
        })
    }

    pub fn set_target(&self, power: f64) {
        self.pid.lock().unwrap().set_set_point(power);
    }

    pub fn target(&self) -> f64 {
        self.pid.lock().unwrap().set_point()
    }

    pub fn last_nudge(&self) -> f64 {
        *self.last_nudge.lock().unwrap()
    }

    pub fn request_interval_ms(&self) -> f64 {
        *self.request_interval_ms.lock().unwrap()
    }

    pub fn pid_snapshot(&self) -> PidSnapshot {
        self.pid.lock().unwrap().snapshot()
    }

    pub fn reset_metrics(&self) {
        self.pid.lock().unwrap().reset_metrics();
    }

    /// Builds the Modbus request handler for the inverter's connection.
    pub fn handler(self: &Arc<Self>) -> RequestHandler {
        let this = Arc::clone(self);

        Arc::new(move |req: ModbusRequest| {
            let mut response = this.meter.build_response(&req, this.dialect);

            let pid = Arc::clone(&this.pid);
            let inverter = Arc::clone(&this.inverter);
            let meter = Arc::clone(&this.meter);
            let last_time = Arc::clone(&this.last_time);
            let last_nudge = Arc::clone(&this.last_nudge);
            let request_interval_ms = Arc::clone(&this.request_interval_ms);
            let reverse = this.reverse;
            let dialect = this.dialect;
            let name = this.name.clone();

            let override_fn = move |register: u16, value: f64| -> f64 {
                if dialect.is_active_power(register) {
                    let now = now_ms();
                    let delta = {
                        let mut last = last_time.lock().unwrap();
                        let delta = now.saturating_sub(*last) as f64 / 1000.0;
                        *last = now;
                        delta
                    };

                    // The inverters poll the meter on their own cadence; that
                    // interval is how often a new command can reach them.
                    if delta > 0.0 {
                        let mut interval = request_interval_ms.lock().unwrap();
                        let sample = delta * 1000.0;
                        *interval = if *interval == 0.0 {
                            sample
                        } else {
                            *interval + INTERVAL_SMOOTHING * (sample - *interval)
                        };
                    }

                    // The unit's control measurement — its battery register,
                    // or its AC port when that register is not a measurement of
                    // itself (`PowerSource`). The loop's stability depends on
                    // this being the same quantity the target is stated in and
                    // carrying the same sign, so both sources are pinned to
                    // "positive = discharging" by tests in `inverters` and
                    // `inverter_controller`.
                    let current = inverter.control_power();
                    let nudge = pid.lock().unwrap().calculate(current, delta);
                    *last_nudge.lock().unwrap() = nudge;

                    tracing::trace!(name, nudge, current, delta, "PID nudge");
                    nudge
                } else if dialect.is_current(register) {
                    let voltage = meter.get_voltage();
                    if voltage != 0.0 {
                        meter.get_active_power() / voltage
                    } else {
                        0.0
                    }
                } else {
                    value
                }
            };

            this.meter
                .modify_response(&mut response, reverse, Some(&override_fn), dialect);

            Some(response)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::meter::{MeterDialect, EEM, SDM630};
    use crate::parser::{ModbusRequest, ModbusResponse};
    use crate::registers::RegisterCache;

    const METER_FC: u8 = 4;

    /// A unit whose two possible measurements are told apart on purpose:
    /// `phantom` is what a battery block fed from the BMS's CAN stream reports
    /// (the whole bank), `ac` what its own AC port measures.
    struct Fixed {
        phantom: f64,
        ac: f64,
    }

    impl Inverter for Fixed {
        fn battery_power(&self) -> f64 {
            self.phantom
        }

        fn control_power(&self) -> f64 {
            self.ac
        }
    }

    fn controller(
        inverter: Fixed,
        target: f64,
        reverse: bool,
        dialect: &'static MeterDialect,
    ) -> Arc<InverterController> {
        let cache = Arc::new(RegisterCache::new());
        cache.store_response(&ModbusResponse::from_regs(
            ModbusRequest::new(1, METER_FC, crate::meter::R_VOLTAGE, 2),
            (230.0f32).to_bits().to_be_bytes().to_vec(),
        ));
        let meter = Meter::new(cache);
        let controller = InverterController::new(
            "test",
            PidController::new(0.3, 0.0, 0.0, 1_500.0),
            Arc::new(inverter) as Arc<dyn Inverter>,
            meter,
            reverse,
            dialect,
        );
        controller.set_target(target);
        controller
    }

    /// What the inverter is actually served at one of its active-power
    /// registers, after the nudge and the line's `reverse`.
    fn served_watts(controller: &Arc<InverterController>, register: u16) -> f32 {
        let handler = controller.handler();
        let response =
            handler(ModbusRequest::new(1, METER_FC, register, 2)).expect("answers its dialect");
        f32::from_bits(u32::from_be_bytes([
            response.regs[0],
            response.regs[1],
            response.regs[2],
            response.regs[3],
        ]))
    }

    /// The loop is negative feedback on the quantity the target is stated in:
    /// an inverter charging less than it was told is shown *import* (which its
    /// firmware answers by charging more), and one charging more is shown
    /// *export*. Both cases run through a solis2-shaped line: `reverse` on,
    /// three-phase `sdm630` dialect, total active power at 52.
    #[test]
    fn the_loop_corrects_towards_the_target_on_a_reversed_three_phase_line() {
        // Asked for 1.5 kW of charge, only pulling 100 W: must be shown import.
        let under = controller(
            Fixed {
                phantom: -6_010.0,
                ac: -100.0,
            },
            -1_500.0,
            true,
            &SDM630,
        );
        assert!(
            served_watts(&under, 52) > 0.0,
            "under-charging must be served import, not export"
        );

        // Asked for 1.5 kW, actually taking 3 kW: must be shown export.
        let over = controller(
            Fixed {
                phantom: -6_010.0,
                ac: -3_000.0,
            },
            -1_500.0,
            true,
            &SDM630,
        );
        assert!(
            served_watts(&over, 52) < 0.0,
            "over-charging must be served export, not import"
        );
    }

    /// ... and it is the *control* measurement it corrects on. Here the phantom
    /// figure says the unit is charging 6 kW (which would command a stop) while
    /// its AC port says it is barely charging at all (which commands more): the
    /// two point in opposite directions, so this fails the moment the loop goes
    /// back to measuring the bank echo.
    #[test]
    fn a_phantom_battery_figure_never_steers_the_loop() {
        let honest = controller(
            Fixed {
                phantom: -6_010.0,
                ac: -100.0,
            },
            -1_500.0,
            true,
            &SDM630,
        );
        let phantom_driven = controller(
            Fixed {
                phantom: -6_010.0,
                ac: -6_010.0,
            },
            -1_500.0,
            true,
            &SDM630,
        );
        let served = served_watts(&honest, 52);
        let served_from_phantom = served_watts(&phantom_driven, 52);
        assert!(
            served > 0.0 && served_from_phantom < 0.0,
            "the two sources must not be interchangeable: {served} vs {served_from_phantom}"
        );
    }

    /// Discharge commands keep the same polarity on the un-reversed EEM line, so
    /// adding a source switch cannot have moved how a line is driven: only the
    /// measurement source changes, never the direction the nudge pushes in.
    #[test]
    fn the_historical_line_still_corrects_the_same_way() {
        let idle = controller(
            Fixed {
                phantom: 0.0,
                ac: 0.0,
            },
            2_000.0,
            false,
            &EEM,
        );
        assert!(
            served_watts(&idle, crate::meter::R_ACTIVE_POWER) > 0.0,
            "a unit asked to discharge while idle is shown import (its firmware dispatches)"
        );
    }
}
