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
    ) -> Arc<Self> {
        Arc::new(Self {
            name: name.into(),
            pid: Arc::new(Mutex::new(pid)),
            inverter,
            meter,
            reverse,
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
            let mut response = this.meter.build_response(&req);

            let pid = Arc::clone(&this.pid);
            let inverter = Arc::clone(&this.inverter);
            let meter = Arc::clone(&this.meter);
            let last_time = Arc::clone(&this.last_time);
            let last_nudge = Arc::clone(&this.last_nudge);
            let request_interval_ms = Arc::clone(&this.request_interval_ms);
            let reverse = this.reverse;
            let name = this.name.clone();

            let override_fn = move |register: u16, value: f64| -> f64 {
                if register == meter::R_ACTIVE_POWER {
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

                    let current = inverter.battery_power();
                    let nudge = pid.lock().unwrap().calculate(current, delta);
                    *last_nudge.lock().unwrap() = nudge;

                    tracing::trace!(name, nudge, current, delta, "PID nudge");
                    nudge
                } else if register == meter::R_CURRENT {
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
                .modify_response(&mut response, reverse, Some(&override_fn));

            Some(response)
        })
    }
}
