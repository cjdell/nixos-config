use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::Context;
use tokio::time::MissedTickBehavior;

use crate::allocation::{Allocation, InverterState, ReserveState};
use crate::config::{Config, InverterConfig};
use crate::control::ControlLaw;
use crate::diagnostics::{ConnectionState, ConnectionStats, Diagnostics, Role};
use crate::discovery::Assignment;
use crate::home_assistant::HomeAssistant;
use crate::influx::InfluxWriter;
use crate::inverter_controller::InverterController;
use crate::inverters::{self, Inverter, InverterDriver};
use crate::meter::{Meter, METER_REGS};
use crate::pid::PidController;
use crate::registers::{ModbusSlaveProxy, RegisterCache};
use crate::telemetry::{
    CentralTelemetry, InverterTelemetry, ReserveTelemetry, StatusSnapshot, Telemetry,
};
use crate::transport::{spawn_modbus_master, ModbusSlaveGroup};
use crate::util::{is_octopus_go_time_range, now_ms};

const CONTROL_INTERVAL: Duration = Duration::from_millis(10);
const PUBLISH_INTERVAL: Duration = Duration::from_millis(200);
const METER_INFLUX_INTERVAL: Duration = Duration::from_millis(100);
const HOME_ASSISTANT_INTERVAL: Duration = Duration::from_millis(1_000);
const METRICS_RESET_INTERVAL_MS: u64 = 60 * 60 * 1_000;
const SERIAL_TIMEOUT: Duration = Duration::from_millis(400);
/// Publish the slow control state (authority estimates, reserve decision) at
/// 1 Hz: it changes over seconds, and the Influx `relay` measurement is
/// already written at 100 Hz.
const ALLOCATION_PUBLISH_TICKS: u32 = 5;
/// A battery-power register that has not refreshed for this long is treated as
/// stale: it is excluded from authority learning and flagged on the dashboard.
const POWER_STALE_MS: u64 = 5_000;
/// The state-of-charge register is polled every 10 s.
const SOC_STALE_MS: u64 = 30_000;

/// One inverter's live plumbing: its configuration, its register cache, the
/// driver that knows how to read it, and the loop that nudges it.
struct InverterRuntime {
    cfg: InverterConfig,
    cache: Arc<RegisterCache>,
    driver: Arc<dyn InverterDriver>,
    controller: Arc<InverterController>,
}

impl InverterRuntime {
    fn id(&self) -> &str {
        self.cfg.id()
    }

    fn name(&self) -> &str {
        &self.cfg.policy.name
    }

    fn fresh(&self, regs: (u8, u16), max_age_ms: u64) -> bool {
        self.cache.is_fresh(regs.0, regs.1, max_age_ms)
    }

    /// This tick's measurement for the allocator. The state of charge is NaN
    /// when the driver has no SOC register, or its register has gone stale, so
    /// the allocator keeps its last known value rather than reading 0% as real.
    fn state(&self) -> InverterState {
        let fresh = self.fresh(self.driver.power_regs(), POWER_STALE_MS);
        let soc = match self.driver.soc_regs() {
            Some(regs) if self.fresh(regs, SOC_STALE_MS) => self.cache.read_i16(regs.0, regs.1),
            _ => f64::NAN,
        };

        InverterState::new(
            self.controller.target(),
            self.driver.battery_power(),
            fresh,
        )
        .with_soc(soc)
    }
}

pub struct Controller {
    cfg: Arc<Config>,
    meter: Arc<Meter>,
    /// The plant, in priority order — index 0 is the primary actuator.
    inverters: Vec<InverterRuntime>,
    law: Arc<Mutex<ControlLaw>>,
    telemetry: Arc<Telemetry>,
    influx: InfluxWriter,
    ha: HomeAssistant,
    use_octopus_go: Arc<AtomicBool>,
    lab_solar_power: Arc<Mutex<f64>>,
    last_metrics_reset: Arc<Mutex<u64>>,
    last_reserve_state: Arc<Mutex<ReserveState>>,
    meter_cache: Arc<RegisterCache>,
    /// Live per-connection health, served to the diagnostics page.
    diagnostics: Arc<Diagnostics>,
}

impl Controller {
    pub fn new(cfg: Arc<Config>) -> anyhow::Result<Arc<Self>> {
        let meter_cache = Arc::new(RegisterCache::new());
        let meter = Meter::new(Arc::clone(&meter_cache));

        // One driver, cache and loop per configured inverter. The allocator and
        // the control law are handed the resulting list and never learn how
        // many there are.
        let mut inverters = Vec::with_capacity(cfg.inverters.len());
        for inverter in &cfg.inverters {
            let cache = Arc::new(RegisterCache::new());
            let driver = inverters::build(&inverter.driver, Arc::clone(&cache))
                .with_context(|| format!("building the driver for inverter {:?}", inverter.id()))?;

            // Per-inverter loops, P-only: they drive each inverter's own
            // firmware towards the share the allocator assigns.
            let controller = InverterController::new(
                inverter.policy.name.clone(),
                PidController::new(inverter.kp, inverter.ki, inverter.kd, inverter.nudge_limit),
                Arc::clone(&driver) as Arc<dyn Inverter>,
                Arc::clone(&meter),
                inverter.reverse,
            );

            inverters.push(InverterRuntime {
                cfg: inverter.clone(),
                cache,
                driver,
                controller,
            });
        }

        let law = Arc::new(Mutex::new(ControlLaw::new(cfg.control.clone(), now_ms())));

        let influx = InfluxWriter::new(cfg.influxdb_url.clone(), cfg.influxdb_token.clone());
        let ha = HomeAssistant::new(
            cfg.home_assistant_api.clone(),
            cfg.home_assistant_bearer_token.clone(),
        );

        let telemetry = Telemetry::new(initial_snapshot(&law, &cfg), 720);

        Ok(Arc::new(Self {
            cfg,
            meter,
            inverters,
            law,
            telemetry,
            influx,
            ha,
            use_octopus_go: Arc::new(AtomicBool::new(false)),
            lab_solar_power: Arc::new(Mutex::new(0.0)),
            last_metrics_reset: Arc::new(Mutex::new(now_ms())),
            last_reserve_state: Arc::new(Mutex::new(ReserveState::PrimaryOnly)),
            meter_cache,
            diagnostics: Diagnostics::new(),
        }))
    }

    pub async fn run(self: Arc<Self>) -> anyhow::Result<()> {
        let cfg = Arc::clone(&self.cfg);
        let connect_timeout = Duration::from_millis(cfg.discovery.connect_timeout_ms);

        // --- Work out which endpoint actually is which, before trusting any ---
        //
        // The remote adapters re-enumerate, so the configured port numbers are
        // hints at best. Nothing below connects to a named role until this has
        // looked at the wires; see `discovery.rs` for how.
        let layout = if cfg.discovery.mode.enabled() {
            crate::discovery::discover(&cfg, Some(&self.diagnostics)).await
        } else {
            let layout = crate::discovery::configured_layout(&cfg);
            self.diagnostics.set_discovery(layout.report.clone());
            layout
        };

        tracing::info!(
            mode = layout.report.mode,
            attempts = layout.report.attempts,
            duration_ms = layout.report.duration_ms,
            candidates = layout.report.candidates,
            assigned = layout.report.assigned,
            unidentified = layout.report.unidentified,
            "endpoint discovery finished"
        );
        for line in &layout.report.log {
            tracing::info!(target: "meter_relay::discovery", "{line}");
        }

        let missing = layout.unidentified_required();
        if !missing.is_empty() {
            let message = format!(
                "startup discovery could not identify {}: refusing to drive a line whose \
                 polarity would be a guess (an inverter answered with another inverter's \
                 reverse setting is driven backwards). Set MR_DISCOVERY_STRICT=false to \
                 start anyway.",
                missing.join(", ")
            );
            if cfg.discovery.strict {
                anyhow::bail!("{message}");
            }
            tracing::error!("{message}");
        }

        // --- Grid meter over its serial port ---
        let meter_assignment = layout.grid_meter().cloned();
        let meter_stats = self.connection("meter", Role::GridMeter, 0, meter_assignment.as_ref());
        let meter_endpoint = meter_stats.endpoint().cloned().ok_or_else(|| {
            anyhow::anyhow!(
                "no grid meter endpoint is available ({}); discovery found no meter and the \
                 configured device is not free",
                cfg.serial_device
            )
        })?;
        let meter_group = ModbusSlaveGroup::new(
            meter_endpoint.clone(),
            "Meter",
            SERIAL_TIMEOUT,
            Arc::clone(&meter_stats),
            connect_timeout,
        );
        ModbusSlaveProxy::new(
            Arc::clone(&meter_group),
            1,
            Arc::clone(&self.meter_cache),
            METER_REGS,
        )
        .init();
        tracing::info!(endpoint = %meter_endpoint, "grid meter connection started");

        // --- Inverter register stats socket, shared by every inverter ---
        let stats_assignment = layout.stats().cloned();
        let stats_connection = self.connection("stats", Role::StatsBus, 1, stats_assignment.as_ref());
        let stats_endpoint = stats_connection.endpoint().cloned().ok_or_else(|| {
            anyhow::anyhow!(
                "no stats endpoint is available ({}:{}); discovery found no stats bus and the \
                 configured socket is not free",
                cfg.inverter_host,
                cfg.stats_port
            )
        })?;
        let stats_group = ModbusSlaveGroup::new(
            stats_endpoint.clone(),
            "Stats",
            SERIAL_TIMEOUT,
            Arc::clone(&stats_connection),
            connect_timeout,
        );
        for inverter in &self.inverters {
            ModbusSlaveProxy::new(
                Arc::clone(&stats_group),
                inverter.cfg.slave,
                Arc::clone(&inverter.cache),
                inverter.driver.telemetry_regs(),
            )
            .init();
        }
        tracing::info!(
            endpoint = %stats_endpoint,
            inverters = self.inverters.len(),
            "stats bus connection started"
        );

        // --- Inverter meter lines: the inverters act as Modbus masters ---
        for (index, inverter) in self.inverters.iter().enumerate() {
            let assignment = layout.meter_line(inverter.id()).cloned();
            let identified = assignment
                .as_ref()
                .map(|assignment| assignment.identified)
                .unwrap_or(false);
            let connection = self.connection(
                inverter.id(),
                Role::MeterEmulator,
                2 + index as u32,
                assignment.as_ref(),
            );

            let Some(endpoint) = connection.endpoint().cloned() else {
                tracing::error!(
                    inverter = inverter.id(),
                    "no endpoint available for this inverter's meter line: it will not be \
                     served, and the inverter will report a metering fault"
                );
                continue;
            };

            if !identified {
                // Strict mode never reaches here (it has already refused to
                // start). With discovery explicitly relaxed, the configured
                // port is served as it was before discovery existed — but the
                // diagnostics page keeps saying it is unverified.
                tracing::warn!(
                    inverter = inverter.id(),
                    endpoint = %endpoint,
                    "serving an unverified meter line because MR_DISCOVERY_STRICT is off"
                );
                connection.set_state(ConnectionState::Unidentified);
            }

            spawn_modbus_master(
                endpoint.clone(),
                inverter.name(),
                inverter.controller.handler(),
                Arc::clone(&connection),
                connect_timeout,
            );
            tracing::info!(
                inverter = inverter.id(),
                endpoint = %endpoint,
                identified,
                "inverter meter line connection started"
            );
        }

        {
            let this = Arc::clone(&self);
            tokio::spawn(async move { this.control_loop().await });
        }
        {
            let this = Arc::clone(&self);
            tokio::spawn(async move { this.publish_loop().await });
        }
        {
            let this = Arc::clone(&self);
            tokio::spawn(async move { this.meter_influx_loop().await });
        }
        {
            let this = Arc::clone(&self);
            tokio::spawn(async move { this.home_assistant_loop().await });
        }

        crate::web::serve(
            Arc::clone(&self.telemetry),
            Arc::clone(&self.diagnostics),
            cfg.web_port,
            cfg.web_dir.clone(),
        )
        .await
    }

    /// The diagnostics row for one connection, carrying whatever discovery
    /// concluded about it. `expected_identity` is the *configured* hint, not
    /// the discovered identity, so a line whose port moved shows as a mismatch
    /// on the diagnostics page instead of silently looking correct.
    fn connection(
        &self,
        id: &str,
        role: Role,
        order: u32,
        assignment: Option<&Assignment>,
    ) -> Arc<ConnectionStats> {
        let expected = assignment
            .and_then(|assignment| assignment.hint.as_ref())
            .and_then(|hint| match hint {
                crate::discovery::Hint::Inverter(id) => Some(id.clone()),
                _ => None,
            });

        let stats = ConnectionStats::new(
            id,
            role,
            assignment.and_then(|assignment| assignment.endpoint.clone()),
            expected,
            order,
        );
        if let Some(assignment) = assignment {
            stats.identify(
                assignment.identity.clone(),
                assignment.identification.clone(),
            );
            if !assignment.identified {
                stats.set_state(ConnectionState::Unidentified);
            }
        }
        self.diagnostics.register(stats)
    }

    async fn control_loop(self: Arc<Self>) {
        let mut interval = tokio::time::interval(CONTROL_INTERVAL);
        interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

        loop {
            interval.tick().await;

            let now = now_ms();
            let meter_power = self.meter.get_active_power();

            let charging =
                self.use_octopus_go.load(Ordering::Relaxed) && is_octopus_go_time_range();

            let states: Vec<InverterState> =
                self.inverters.iter().map(InverterRuntime::state).collect();

            let (allocation, needed, reserve_state) = {
                let mut law = self.law.lock().unwrap();
                law.set_meter_target(self.cfg.meter_target_power);
                law.set_charging(charging);

                let allocation = if charging {
                    law.tick_charge(&states, now)
                } else {
                    law.tick_balance(meter_power, &states, now)
                };
                let needed = law.pid_snapshot().output;
                (allocation, needed, law.allocation().state)
            };

            // Hand each inverter the share the allocator gave it.
            for (inverter, share) in self.inverters.iter().zip(allocation.inverters.iter()) {
                inverter.controller.set_target(share.target);
            }

            {
                let mut last = self.last_reserve_state.lock().unwrap();
                if *last != reserve_state {
                    tracing::info!(
                        state = reserve_state.as_str(),
                        targets = ?allocation.targets(),
                        "reserve state changed"
                    );
                    *last = reserve_state;
                }
            }

            // Line protocol: fields are comma-separated; the first space ends
            // the field set and InfluxDB would read the next field as the
            // timestamp ("bad timestamp" 400s).
            let mut fields = format!("meter_power={meter_power},needed_power={needed}");
            for inverter in &self.inverters {
                fields.push_str(&format!(
                    ",{}_actual_power={},{}_target_power={},{}_nudge={}",
                    inverter.id(),
                    inverter.driver.battery_power(),
                    inverter.id(),
                    inverter.controller.target(),
                    inverter.id(),
                    inverter.controller.last_nudge(),
                ));
            }
            self.influx.write(format!("relay {fields} {now}"));
        }
    }

    async fn publish_loop(self: Arc<Self>) {
        let mut interval = tokio::time::interval(PUBLISH_INTERVAL);
        interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
        let mut publish_tick: u32 = 0;

        loop {
            interval.tick().await;

            let now = now_ms();
            let charging =
                self.use_octopus_go.load(Ordering::Relaxed) && is_octopus_go_time_range();

            let (pid, allocation, engaged, reserve_soc) = {
                let law = self.law.lock().unwrap();
                (
                    law.pid_snapshot(),
                    law.allocation().clone(),
                    law.allocator().engaged(),
                    law.allocator().reserve_soc(),
                )
            };

            self.telemetry.record(StatusSnapshot {
                ts: now,
                central: CentralTelemetry {
                    grid_power: self.meter.get_active_power(),
                    grid_voltage: self.meter.get_voltage(),
                    meter_target: self.cfg.meter_target_power,
                    pid,
                },
                inverters: self.inverter_telemetry(&allocation),
                reserve: ReserveTelemetry {
                    engaged,
                    state: allocation.state,
                    share: allocation.reserve_share,
                    absorbed: allocation.absorbed,
                    unmet: allocation.unmet,
                    soc: reserve_soc,
                    total_discharge_limit: allocation.total_discharge_limit,
                    total_charge_limit: allocation.total_charge_limit,
                },
                lab_solar_power: *self.lab_solar_power.lock().unwrap(),
                use_octopus_go: self.use_octopus_go.load(Ordering::Relaxed),
                charging,
            });

            publish_tick = publish_tick.wrapping_add(1);
            if publish_tick.is_multiple_of(ALLOCATION_PUBLISH_TICKS) {
                let mut fields = format!(
                    "total_discharge_limit={},total_charge_limit={},reserve_share={},absorbed={},unmet={},solax_soc={}",
                    allocation.total_discharge_limit,
                    allocation.total_charge_limit,
                    allocation.reserve_share,
                    allocation.absorbed,
                    allocation.unmet,
                    reserve_soc,
                );
                for inverter in &self.inverters {
                    let (discharge, charge) = allocation
                        .by_id(inverter.id())
                        .map(|share| (share.discharge_limit, share.charge_limit))
                        .unwrap_or((0.0, 0.0));
                    fields.push_str(&format!(
                        ",{}_discharge_limit={},{}_charge_limit={},{}_request_ms={}",
                        inverter.id(),
                        discharge,
                        inverter.id(),
                        charge,
                        inverter.id(),
                        inverter.controller.request_interval_ms(),
                    ));
                }
                self.influx.write(format!(
                    "allocation,state={} {fields} {now}",
                    allocation.state.as_str()
                ));
            }

            let last_reset = *self.last_metrics_reset.lock().unwrap();
            if now.saturating_sub(last_reset) >= METRICS_RESET_INTERVAL_MS {
                self.law.lock().unwrap().reset_metrics();
                for inverter in &self.inverters {
                    inverter.controller.reset_metrics();
                }
                *self.last_metrics_reset.lock().unwrap() = now;
            }
        }
    }

    async fn meter_influx_loop(self: Arc<Self>) {
        let mut interval = tokio::time::interval(METER_INFLUX_INTERVAL);
        interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

        loop {
            interval.tick().await;
            self.influx.write(format!(
                "power,meter=grid power={} {}",
                self.meter.get_active_power(),
                now_ms()
            ));
        }
    }

    async fn home_assistant_loop(self: Arc<Self>) {
        let mut interval = tokio::time::interval(HOME_ASSISTANT_INTERVAL);
        interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

        loop {
            interval.tick().await;

            self.publish_meter().await;
            for inverter in &self.inverters {
                self.publish_inverter(inverter).await;
            }
            self.publish_reserve().await;

            let use_octopus_go = self.ha.read_boolean("octopus_go").await;
            self.use_octopus_go.store(use_octopus_go, Ordering::Relaxed);

            let lab_solar_power = self.ha.read_float("plug_01_energy_power").await;
            *self.lab_solar_power.lock().unwrap() = lab_solar_power;
        }
    }

    async fn publish_meter(&self) {
        let meter_power = (self.meter.get_active_power() * 100.0).round() / 100.0;

        self.ha
            .send("meter_power", "Meter Power", meter_power, "W")
            .await;

        let import = if meter_power > 0.0 { meter_power } else { 0.0 };
        let export = if meter_power < 0.0 { -meter_power } else { 0.0 };

        self.ha
            .send("meter_import_power", "Meter Import Power", import, "W")
            .await;
        self.ha
            .send("meter_export_power", "Meter Export Power", export, "W")
            .await;

        let price = if is_octopus_go_time_range() { 0.085 } else { 0.2984 };
        self.ha
            .send(
                "energy_current_price_per_kwh",
                "Energy Current Price Per kWh",
                price,
                "GBP/kWh",
            )
            .await;
    }

    /// Publishes what the allocator decided, so the reserve is visible to
    /// automations and to anything watching Home Assistant.
    async fn publish_reserve(&self) {
        let allocation = self.law.lock().unwrap().allocation().clone();

        self.ha
            .send_str(
                "solax_reserve_state",
                "Solax Reserve State",
                allocation.state.as_str(),
                "",
            )
            .await;
        self.ha
            .send(
                "solax_reserve_power",
                "Solax Reserve Power",
                allocation.reserve_share,
                "W",
            )
            .await;
        self.ha
            .send(
                "inverter_authority",
                "Inverter Authority",
                allocation.total_discharge_limit,
                "W",
            )
            .await;

        // The first reserve's own authority. Named for the Solax it has always
        // been, so existing automations keep working on a two-inverter plant.
        if let Some(reserve) = allocation.inverters.get(1) {
            self.ha
                .send(
                    "solax_authority",
                    "Solax Authority",
                    reserve.discharge_limit,
                    "W",
                )
                .await;
        }
    }

    /// One inverter's readings, published under the entity ids its driver has
    /// always used (see `InverterConfig::ha_prefix`).
    async fn publish_inverter(&self, inverter: &InverterRuntime) {
        let readings = inverter.driver.readings();
        let power = readings.battery_power;
        let charge = if power < 0.0 { -power } else { 0.0 };
        let discharge = if power > 0.0 { power } else { 0.0 };

        // A couple of drivers published their power registers under longer
        // names before this generalised; keep them.
        let legacy = inverter.cfg.driver == "solis";
        let prefix = inverter.cfg.ha_prefix.as_str();
        let name = inverter.name();
        let field = |generic: &str, legacy_name: &str| -> String {
            if legacy {
                format!("{prefix}_{legacy_name}")
            } else {
                format!("{prefix}_{generic}")
            }
        };

        let mut numeric: Vec<(String, String, f64, &'static str)> = vec![
            (
                field("power", "battery_power"),
                format!("{name} Battery Power"),
                power,
                "W",
            ),
            (
                field("charge_power", "battery_charge_power"),
                format!("{name} Battery Charge Power"),
                charge,
                "W",
            ),
            (
                field("discharge_power", "battery_discharge_power"),
                format!("{name} Battery Discharge Power"),
                discharge,
                "W",
            ),
        ];

        let mut optional = |value: Option<f64>,
                            generic: &str,
                            legacy_name: &str,
                            label: &str,
                            unit: &'static str| {
            if let Some(value) = value {
                numeric.push((
                    field(generic, legacy_name),
                    format!("{name} {label}"),
                    value,
                    unit,
                ));
            }
        };
        optional(
            readings.percentage,
            "percentage",
            "percentage",
            "Percentage",
            "%",
        );
        optional(readings.solar_power, "solar_power", "pv_power", "PV Power", "W");
        optional(
            readings.solar_voltage,
            "solar_voltage",
            "pv_voltage_2",
            "PV Voltage 2",
            "V",
        );
        optional(
            readings.battery_voltage,
            "battery_voltage",
            "battery_voltage",
            "Battery Voltage",
            "V",
        );
        optional(
            readings.load_power,
            "load_power",
            "output_power",
            "Output Power",
            "W",
        );
        optional(
            readings.ac_voltage,
            "ac_voltage",
            "ac_voltage",
            "AC Voltage",
            "V",
        );

        for (entity, label, value, unit) in numeric {
            self.ha.send(&entity, &label, value, unit).await;
        }

        if let Some(status) = readings.status {
            self.ha
                .send_str(
                    &field("status", "status"),
                    &format!("{name} Status"),
                    &status,
                    "",
                )
                .await;
        }
    }

    fn inverter_telemetry(&self, allocation: &Allocation) -> Vec<InverterTelemetry> {
        self.inverters
            .iter()
            .zip(allocation.inverters.iter())
            .map(|(inverter, share)| {
                let readings = inverter.driver.readings();
                let power_regs = inverter.driver.power_regs();

                InverterTelemetry {
                    id: inverter.id().to_string(),
                    name: inverter.name().to_string(),
                    primary: share.primary,
                    present: inverter.cache.contains(power_regs.0, power_regs.1),
                    stale: !inverter.fresh(power_regs, POWER_STALE_MS),
                    battery_power: readings.battery_power,
                    solar_power: readings.solar_power,
                    battery_voltage: readings.battery_voltage,
                    solar_voltage: readings.solar_voltage,
                    ac_voltage: readings.ac_voltage,
                    load_power: readings.load_power,
                    percentage: readings.percentage,
                    status: readings.status,
                    target: share.target,
                    last_nudge: inverter.controller.last_nudge(),
                    discharge_limit: share.discharge_limit,
                    charge_limit: share.charge_limit,
                    absorbing: share.absorbing,
                    request_interval_ms: inverter.controller.request_interval_ms(),
                    pid: inverter.controller.pid_snapshot(),
                }
            })
            .collect()
    }
}

fn initial_snapshot(law: &Arc<Mutex<ControlLaw>>, cfg: &Config) -> StatusSnapshot {
    let (pid, allocation) = {
        let law = law.lock().unwrap();
        (law.pid_snapshot(), law.allocation().clone())
    };

    StatusSnapshot {
        ts: now_ms(),
        central: CentralTelemetry {
            grid_power: 0.0,
            grid_voltage: 0.0,
            meter_target: cfg.meter_target_power,
            pid: pid.clone(),
        },
        inverters: allocation
            .inverters
            .iter()
            .map(|share| empty_inverter(share, pid.clone()))
            .collect(),
        reserve: ReserveTelemetry {
            engaged: false,
            state: ReserveState::PrimaryOnly,
            share: 0.0,
            absorbed: 0.0,
            unmet: 0.0,
            soc: 0.0,
            total_discharge_limit: 0.0,
            total_charge_limit: 0.0,
        },
        lab_solar_power: 0.0,
        use_octopus_go: false,
        charging: false,
    }
}

fn empty_inverter(share: &crate::allocation::InverterAllocation, pid: crate::pid::PidSnapshot) -> InverterTelemetry {
    InverterTelemetry {
        id: share.id.clone(),
        name: share.name.clone(),
        primary: share.primary,
        present: false,
        stale: false,
        battery_power: 0.0,
        solar_power: None,
        battery_voltage: None,
        solar_voltage: None,
        ac_voltage: None,
        load_power: None,
        percentage: None,
        status: None,
        target: 0.0,
        last_nudge: 0.0,
        discharge_limit: 0.0,
        charge_limit: 0.0,
        absorbing: false,
        request_interval_ms: 0.0,
        pid,
    }
}
