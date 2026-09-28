use std::collections::VecDeque;
use std::sync::{Arc, RwLock};

use serde::Serialize;
use tokio::sync::broadcast;

use crate::allocation::ReserveState;
use crate::pid::PidSnapshot;

/// One inverter's dashboard row.
///
/// Readings are `Option`s because the plant is general: a make/model reports
/// the registers it has. A Solax, for instance, exposes nothing but battery
/// power and state of charge, and saying so is honest — the alternative is the
/// 0.0 this used to publish, which reads as "measured zero" on the dashboard.
#[derive(Clone, Debug, Serialize)]
pub struct InverterTelemetry {
    /// Stable key, matching the policy id ("solis").
    pub id: String,
    pub name: String,
    /// True for priority 0, the always-on-line actuator.
    pub primary: bool,
    pub present: bool,
    /// True when the registers behind this inverter have stopped refreshing.
    pub stale: bool,
    pub battery_power: f64,
    pub solar_power: Option<f64>,
    pub battery_voltage: Option<f64>,
    pub solar_voltage: Option<f64>,
    pub ac_voltage: Option<f64>,
    pub load_power: Option<f64>,
    pub percentage: Option<f64>,
    pub status: Option<String>,
    pub target: f64,
    pub last_nudge: f64,
    /// Power this inverter has been observed to deliver / accept (W).
    pub discharge_limit: f64,
    pub charge_limit: f64,
    /// True while this inverter is being asked to absorb surplus (charge).
    pub absorbing: bool,
    /// Mean interval between this inverter's meter requests (ms).
    pub request_interval_ms: f64,
    pub pid: PidSnapshot,
}

#[derive(Clone, Debug, Serialize)]
pub struct CentralTelemetry {
    pub grid_power: f64,
    pub grid_voltage: f64,
    pub meter_target: f64,
    pub pid: PidSnapshot,
}

/// State of the reserve group: whether it is being used, and why.
#[derive(Clone, Debug, Serialize)]
pub struct ReserveTelemetry {
    pub engaged: bool,
    pub state: ReserveState,
    /// Demand the reserve is covering right now (W, discharge).
    pub share: f64,
    /// Surplus the reserve is absorbing right now (W, charge).
    pub absorbed: f64,
    /// Demand the engaged set could not cover (W): what the grid still sees.
    pub unmet: f64,
    /// State of charge of the first reserve inverter (%), for a headline figure.
    pub soc: f64,
    /// Authority the engaged set has, and what the primary alone would have had.
    pub total_discharge_limit: f64,
    pub total_charge_limit: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct StatusSnapshot {
    pub ts: u64,
    pub central: CentralTelemetry,
    /// One entry per inverter, in the plant's priority order.
    pub inverters: Vec<InverterTelemetry>,
    pub reserve: ReserveTelemetry,
    pub lab_solar_power: f64,
    pub use_octopus_go: bool,
    pub charging: bool,
}

impl StatusSnapshot {
    /// The named inverter, or `None` if it is not in the plant.
    pub fn inverter(&self, id: &str) -> Option<&InverterTelemetry> {
        self.inverters.iter().find(|inv| inv.id == id)
    }
}

/// Shared latest telemetry plus a bounded history buffer, with a broadcast
/// channel for Server-Sent Events clients.
pub struct Telemetry {
    inner: RwLock<StatusSnapshot>,
    history: RwLock<VecDeque<StatusSnapshot>>,
    tx: broadcast::Sender<StatusSnapshot>,
    max_history: usize,
}

impl Telemetry {
    pub fn new(initial: StatusSnapshot, max_history: usize) -> Arc<Self> {
        let (tx, _) = broadcast::channel(64);
        Arc::new(Self {
            inner: RwLock::new(initial),
            history: RwLock::new(VecDeque::with_capacity(max_history)),
            tx,
            max_history,
        })
    }

    pub fn record(&self, snapshot: StatusSnapshot) {
        {
            let mut inner = self.inner.write().unwrap();
            *inner = snapshot.clone();
        }
        {
            let mut history = self.history.write().unwrap();
            history.push_back(snapshot.clone());
            while history.len() > self.max_history {
                history.pop_front();
            }
        }
        let _ = self.tx.send(snapshot);
    }

    pub fn snapshot(&self) -> StatusSnapshot {
        self.inner.read().unwrap().clone()
    }

    pub fn history(&self) -> Vec<StatusSnapshot> {
        self.history.read().unwrap().iter().cloned().collect()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<StatusSnapshot> {
        self.tx.subscribe()
    }
}
