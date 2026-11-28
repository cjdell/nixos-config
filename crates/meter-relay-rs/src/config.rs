use std::net::IpAddr;
use std::path::PathBuf;

use anyhow::{anyhow, bail, Context};

use crate::allocation::{AllocatorConfig, InverterPolicy};
use crate::control::ControlConfig;
use crate::endpoint::{self, Endpoint};
use crate::inverters;
use crate::serial;

/// Everything the controller needs to bring one inverter on line.
///
/// A *driver* is the make/model-specific part — the register map to poll and
/// the accessors that turn those registers into watts. Several inverters may
/// share a driver (a second Solax, say), which is what makes adding hardware a
/// configuration change rather than a code change. The control policy travels
/// separately, in [`InverterPolicy`], because the allocator deliberately knows
/// nothing about makes and models.
#[derive(Clone, Debug)]
pub struct InverterConfig {
    pub policy: InverterPolicy,
    /// Known driver name, e.g. "solis" or "solax".
    pub driver: String,
    /// TCP port the inverter connects to for its view of the grid meter.
    pub port: u16,
    /// Modbus slave address this inverter is polled at on the shared stats
    /// socket.
    pub slave: u8,
    pub kp: f64,
    pub ki: f64,
    pub kd: f64,
    /// Clamp on the phantom active-power value this inverter's loop may write
    /// (W). It bounds the *nudge*, which is a grid-power target and may exceed
    /// the inverter's own rating — the inverter clamps to its hardware limit.
    pub nudge_limit: f64,
    /// Whether the phantom active-power reading is negated for this inverter.
    pub reverse: bool,
    /// Prefix for this inverter's Home Assistant entity ids. Home Assistant
    /// entity ids are part of a live installation's contract (automations and
    /// dashboards reference them), so each driver keeps the names it has always
    /// published rather than being renamed by the generalisation.
    pub ha_prefix: String,
    /// Register that proves this driver is present, read by startup discovery
    /// to identify the stats bus without building a driver.
    pub probe_regs: (u8, u16),
    /// Meter polls this make/model is known to send, used by startup discovery
    /// to tell one inverter's meter line from another's when the endpoint
    /// enumeration has shuffled. `MR_<ID>_METER_POLL` overrides it.
    pub meter_poll: Vec<(u8, u16, u16)>,
    /// The meter *dialect* served on this inverter's meter line — which
    /// register positions carry volts/amps/watts in the inverter's address
    /// space, and therefore where this line's PID nudge rides. Selected by
    /// `MR_<ID>_METER_DIALECT` (`eem` is the historical single-phase map
    /// every line used before three-phase inverters joined the plant).
    pub meter_dialect: &'static crate::meter::MeterDialect,
    /// Which of the unit's own registers the loops measure it by — the battery
    /// register unless `MR_<ID>_POWER_SOURCE=ac` says its battery block cannot
    /// be trusted as a measurement of this inverter. See [`PowerSource`].
    pub power_source: crate::inverters::PowerSource,
}

impl InverterConfig {
    pub fn id(&self) -> &str {
        &self.policy.id
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    pub home_assistant_api: String,
    pub home_assistant_bearer_token: String,
    pub influxdb_url: String,
    pub influxdb_token: String,

    pub serial_device: String,
    pub serial_baud: u32,
    /// Every local serial candidate: the configured device, anything
    /// `MR_SERIAL_DEVICES` names, and — unless `MR_SERIAL_AUTO=false` — every
    /// port the kernel lists under `/dev/serial/by-id` and `/dev/serial/by-path`
    /// (`serial.rs`), minus `MR_SERIAL_EXCLUDE`. Discovery finds the grid meter
    /// by probing, so a meter that moves to another adapter moves with it.
    pub serial_devices: Vec<Endpoint>,
    /// How long the grid meter's *device node* may be absent from the bus
    /// (its open having kept failing for that long) before the process exits
    /// so a supervised restart re-runs discovery. 0 disables the check.
    /// `MR_METER_GONE_AFTER_MS`.
    pub meter_gone_after_ms: u64,
    /// An explicit remote candidate list (`MR_ENDPOINTS`), if one was given.
    /// Empty means "derive the candidates from the ports below".
    pub endpoints: Vec<Endpoint>,
    pub inverter_host: String,
    /// The plant, in priority order: index 0 is the primary actuator.
    pub inverters: Vec<InverterConfig>,
    /// Shared socket both inverters are polled on for telemetry registers.
    pub stats_port: u16,

    /// Startup auto-detection settings. See `discovery.rs`.
    pub discovery: DiscoverySettings,

    /// Where to shout when the plant should not be trusted. See `alerts.rs`.
    pub alerts: AlertSettings,

    pub web_port: u16,
    pub web_dir: PathBuf,

    /// Grid power the relay drives the meter to (W, positive = import; the
    /// default of +50 therefore means "hold ~50 W of export").
    pub meter_target_power: f64,

    pub control: ControlConfig,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiscoveryMode {
    /// Listen and probe the serial endpoints at startup.
    Auto,
    /// Trust the configured ports exactly as before, and only report them.
    Off,
}

impl DiscoveryMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Off => "off",
        }
    }

    pub fn enabled(self) -> bool {
        self == Self::Auto
    }
}

/// Startup auto-detection settings.
#[derive(Clone, Debug)]
pub struct DiscoverySettings {
    pub mode: DiscoveryMode,
    /// How long each silent endpoint is listened to for inverter meter polls.
    pub listen_ms: u64,
    /// How long a probe waits for a reply.
    pub probe_ms: u64,
    /// How long opening an endpoint may take.
    pub connect_timeout_ms: u64,
    /// How many identify-and-retry rounds to run: an inverter may still be
    /// booting when the relay starts.
    pub attempts: u32,
    /// Refuse to start when a required connection cannot be identified, rather
    /// than serving a line whose polarity is a guess.
    pub strict: bool,
    /// Print what the endpoints are and exit without starting the service
    /// (`MR_DISCOVERY_ONLY`). Needs no credentials: it touches only the wires.
    pub only: bool,
}

impl Default for DiscoverySettings {
    fn default() -> Self {
        Self {
            mode: DiscoveryMode::Auto,
            listen_ms: 3_000,
            probe_ms: 250,
            connect_timeout_ms: 3_000,
            attempts: 3,
            strict: true,
            only: false,
        }
    }
}

/// Where to shout when the plant should not be trusted (`alerts.rs`). The
/// Home Assistant *health sensor* is always published — these are the push
/// channels on top of it.
#[derive(Clone, Debug)]
pub struct AlertSettings {
    /// `notify.*` services to fire on every Home Assistant instance reachable
    /// via `MR_HOME_ASSISTANT_API` (`MR_ALERT_HA_SERVICES`, comma-separated,
    /// e.g. `notify.mobile_app_pixel_8_pro`). Empty = sensor only, no push.
    pub ha_services: Vec<String>,
    /// Optional generic webhook (`MR_ALERT_WEBHOOK_URL`): a JSON `POST` of
    /// `{"title","message"}` — works for ntfy, HA webhooks, and whatever
    /// else listens.
    pub webhook_url: String,
    /// How long a problem must persist before it is shouted about
    /// (`MR_ALERT_GRACE_MS`) — reconnect backoff flapping must not page.
    pub grace_ms: u64,
    /// While problems remain active, re-shout the full list this often
    /// (`MR_ALERT_REPEAT_MS`, default 30 min) — a once-only message is a
    /// message that can be missed.
    pub repeat_ms: u64,
}

/// Make/model defaults: the meter port it connects to, the slave address it is
/// polled at on the stats socket, the per-inverter PID gains, whether its
/// phantom meter reading is negated, and the Home Assistant entity-id prefix it
/// has always published under.
///
/// **Adding an inverter model starts here.** A driver name that is not listed
/// is a startup error rather than a silent no-op, so a typo surfaces at once.
struct DriverDefaults {
    port: u16,
    slave: u8,
    kp: f64,
    ki: f64,
    nudge_limit: f64,
    reverse: bool,
    ha_prefix: &'static str,
}

fn driver_defaults(driver: &str) -> anyhow::Result<DriverDefaults> {
    match driver {
        // Solis wants a gentle P term, reads the meter reversed, and has
        // published its readings as `sensor.inverter_*` since the TypeScript
        // service.
        "solis" => Ok(DriverDefaults {
            port: 2000,
            slave: 2,
            kp: 0.3,
            ki: 0.0,
            nudge_limit: 3_600.0,
            reverse: true,
            ha_prefix: "inverter",
        }),
        // Solax does not like sudden changes, hence a gentler P term.
        "solax" => Ok(DriverDefaults {
            port: 2001,
            slave: 1,
            kp: 0.5,
            ki: 0.0,
            nudge_limit: 3_000.0,
            reverse: false,
            ha_prefix: "solax",
        }),
        other => Err(anyhow!(
            "unknown inverter driver {other:?}: add it to driver_defaults() and to the \
             driver factory in inverters.rs"
        )),
    }
}

/// The meter polls a driver is *known* to send, taken from a capture of the
/// live lines (`scripts/capture-serial.py`). Startup discovery matches what it
/// hears against these to work out which shuffled endpoint belongs to which
/// inverter.
///
/// **Adding an inverter model means adding its fingerprint here** (or setting
/// `MR_<ID>_METER_POLL` on the host). An inverter with no fingerprint cannot be
/// placed, and in strict mode that refuses to start — the diagnostics page and
/// the capture script exist to make that a five-minute fix rather than a
/// mystery.
///
/// The patterns are what the *other* driver does not send: the Solis's
/// 76-register bulk read, and the Solax's small reads. A driver's traffic is
/// not fixed — the Solax scans for its meter (`fc3 reg 11` at both candidate
/// addresses, about 4 Hz) while it has none, then polls active power
/// (`fc4 reg 12`) and `fc4 reg 74` once it does — so list every pattern seen in
/// either state. Discovery scores a match on the patterns it recognises and
/// ignores the ones this table has never heard of.
fn driver_meter_poll(driver: &str) -> Vec<(u8, u16, u16)> {
    match driver {
        // A bulk input-register read of the whole meter map, plus the running
        // energy total, alternating at about 1 Hz.
        "solis" => vec![(4, 0, 76), (4, 342, 2)],
        // Meter scan and normal running, measured on the live line.
        "solax" => vec![(4, 12, 2), (3, 11, 1), (4, 74, 2)],
        _ => Vec::new(),
    }
}

/// `4:342:2,4:0:76` → `[(4, 342, 2), (4, 0, 76)]`.
fn parse_meter_poll(spec: &str) -> anyhow::Result<Vec<(u8, u16, u16)>> {
    let mut out = Vec::new();
    for raw in spec.split(',') {
        let item = raw.trim();
        if item.is_empty() {
            continue;
        }
        let parts: Vec<&str> = item.split(':').collect();
        if parts.len() != 3 {
            bail!("{item:?} is not fc:register:count");
        }
        let number = |value: &str, what: &str| -> anyhow::Result<u32> {
            value
                .trim()
                .parse()
                .with_context(|| format!("{item:?}: {what} must be a number"))
        };
        let function_code = number(parts[0], "the function code")?;
        if function_code > u8::MAX as u32 {
            bail!("{item:?}: function codes are one byte");
        }
        let register = number(parts[1], "the register")?;
        if register > u16::MAX as u32 {
            bail!("{item:?}: registers are 16 bits");
        }
        let count = number(parts[2], "the count")?;
        if count > u16::MAX as u32 {
            bail!("{item:?}: register counts are 16 bits");
        }
        out.push((function_code as u8, register as u16, count as u16));
    }
    if out.is_empty() {
        bail!("no meter-poll patterns in {spec:?}");
    }
    Ok(out)
}

/// `solax2` -> `Solax2`, for a default display name.
fn titlecase(id: &str) -> String {
    let mut chars = id.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => id.to_string(),
    }
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        // Load .env without clobbering variables already set by systemd/CI.
        let _ = dotenvy::dotenv();

        let required = |key: &str| -> anyhow::Result<String> {
            std::env::var(key).map_err(|_| anyhow!("missing required environment variable {key}"))
        };
        let optional = |key: &str, default: &str| -> String {
            std::env::var(key).unwrap_or_else(|_| default.to_string())
        };
        let number = |key: &str, default: f64| -> anyhow::Result<f64> {
            match std::env::var(key) {
                Ok(value) => value
                    .parse::<f64>()
                    .with_context(|| format!("{key} must be a number, got {value:?}")),
                Err(_) => Ok(default),
            }
        };
        let millis = |key: &str, default: u64| -> anyhow::Result<u64> {
            match std::env::var(key) {
                Ok(value) => value
                    .parse::<u64>()
                    .with_context(|| format!("{key} must be a whole number of ms, got {value:?}")),
                Err(_) => Ok(default),
            }
        };
        let port = |key: &str, default: u16| -> anyhow::Result<u16> {
            match std::env::var(key) {
                Ok(value) => value
                    .parse::<u16>()
                    .with_context(|| format!("{key} must be a valid port, got {value:?}")),
                Err(_) => Ok(default),
            }
        };
        let boolean = |key: &str, default: bool| -> anyhow::Result<bool> {
            match std::env::var(key) {
                Ok(value) => match value.trim().to_ascii_lowercase().as_str() {
                    "1" | "true" | "yes" | "on" => Ok(true),
                    "0" | "false" | "no" | "off" => Ok(false),
                    _ => Err(anyhow!("{key} must be a boolean, got {value:?}")),
                },
                Err(_) => Ok(default),
            }
        };
        let optional_number = |key: &str| -> anyhow::Result<Option<f64>> {
            match std::env::var(key) {
                Ok(value) => Ok(Some(
                    value
                        .parse::<f64>()
                        .with_context(|| format!("{key} must be a number, got {value:?}"))?,
                )),
                Err(_) => Ok(None),
            }
        };

        let inverter_host = optional("MR_INVERTER_HOST", "192.168.49.30");
        inverter_host
            .parse::<IpAddr>()
            .with_context(|| format!("MR_INVERTER_HOST must be an IP address, got {inverter_host:?}"))?;

        let inverters = load_inverters(&optional, &number, &port, &boolean, &optional_number)?;

        // Serial candidates. The grid meter is a local USB device, and its
        // stable path is not its identity: on 2026-11-27 the adapter carrying
        // it died on the USB bus *fourteen seconds after discovery had
        // confirmed it as the meter*, and the relay — whose only candidate was
        // that one path — dialled the dead name for nine hours. The configured
        // device stays (it is the grid-meter hint discovery falls back to), but
        // enumeration offers every other local port to discovery as well, so
        // the meter is found by its answers wherever it now lives.
        let serial_baud = port("MR_SERIAL_BAUD", endpoint::DEFAULT_BAUD as u16)? as u32;
        let serial_device = optional(
            "MR_SERIAL_DEVICE",
            "/dev/serial/by-id/usb-FTDI_USB_Serial_Converter_FTB6SPL3-if00-port0",
        );
        let mut serial_devices = match optional("MR_SERIAL_DEVICES", "") {
            spec if spec.trim().is_empty() => Vec::new(),
            spec => endpoint::parse_specs(&spec, serial_baud)
                .context("parsing MR_SERIAL_DEVICES")?,
        };
        let configured_device = Endpoint::serial(serial_device.clone(), serial_baud);
        if !serial_devices.contains(&configured_device) {
            serial_devices.insert(0, configured_device);
        }
        if boolean("MR_SERIAL_AUTO", true)? {
            let exclude = split_list(&optional("MR_SERIAL_EXCLUDE", ""));
            let dirs: Vec<PathBuf> = split_list(&optional(
                "MR_SERIAL_DIRS",
                "/dev/serial/by-id,/dev/serial/by-path",
            ))
            .into_iter()
            .map(PathBuf::from)
            .collect();
            serial_devices.extend(serial::candidates(
                &dirs,
                serial_baud,
                &exclude,
                &serial_devices,
            ));
        }
        let meter_gone_after_ms = millis("MR_METER_GONE_AFTER_MS", 60_000)?;

        let endpoints = match optional("MR_ENDPOINTS", "") {
            spec if spec.trim().is_empty() => Vec::new(),
            spec => endpoint::parse_specs(&spec, serial_baud).context("parsing MR_ENDPOINTS")?,
        };

        let strict = boolean("MR_DISCOVERY_STRICT", true)?;
        let discovery_only = boolean("MR_DISCOVERY_ONLY", false)?;
        let discovery = DiscoverySettings {
            mode: match optional("MR_DISCOVERY", "auto").trim().to_ascii_lowercase().as_str() {
                "auto" | "on" | "1" | "true" | "yes" => DiscoveryMode::Auto,
                "off" | "0" | "false" | "no" | "none" => DiscoveryMode::Off,
                other => bail!("MR_DISCOVERY must be auto or off, got {other:?}"),
            },
            listen_ms: millis("MR_DISCOVERY_LISTEN_MS", 3_000)?,
            probe_ms: millis("MR_DISCOVERY_PROBE_MS", 250)?,
            connect_timeout_ms: millis("MR_CONNECT_TIMEOUT_MS", 3_000)?,
            attempts: millis("MR_DISCOVERY_ATTEMPTS", 3)?.clamp(1, 20) as u32,
            strict,
            only: discovery_only,
        };

        let alerts = AlertSettings {
            ha_services: split_list(&optional("MR_ALERT_HA_SERVICES", "")),
            webhook_url: optional("MR_ALERT_WEBHOOK_URL", "").trim().to_string(),
            grace_ms: millis("MR_ALERT_GRACE_MS", 60_000)?,
            repeat_ms: millis("MR_ALERT_REPEAT_MS", 1_800_000)?,
        };

        // A discovery-only run touches nothing but the serial endpoints, so it
        // must not require the publishing credentials: that is the whole point
        // of being able to ask the question on its own.
        let credential = |key: &str| -> anyhow::Result<String> {
            if discovery_only {
                Ok(String::new())
            } else {
                required(key)
            }
        };

        let defaults = AllocatorConfig::default();
        let allocator = AllocatorConfig {
            // The reserve gate is plant-level, not per-inverter: it decides when
            // the reserve *group* joins in. The MR_SOLAX_* spellings are still
            // honoured as fallbacks so existing deployments keep working.
            wake_error_w: number(
                "MR_RESERVE_WAKE_ERROR",
                number("MR_SOLAX_WAKE_ERROR", defaults.wake_error_w)?,
            )?,
            wake_delay_ms: millis(
                "MR_RESERVE_WAKE_DELAY_MS",
                millis("MR_SOLAX_WAKE_DELAY_MS", defaults.wake_delay_ms)?,
            )?,
            release_margin_w: number(
                "MR_RESERVE_RELEASE_MARGIN",
                number("MR_SOLAX_RELEASE_MARGIN", defaults.release_margin_w)?,
            )?,
            release_delay_ms: millis(
                "MR_RESERVE_RELEASE_DELAY_MS",
                millis("MR_SOLAX_RELEASE_DELAY_MS", defaults.release_delay_ms)?,
            )?,
            // The plant's priority order is the inverter list's order.
            inverters: inverters.iter().map(|inv| inv.policy.clone()).collect(),
        };

        let control = ControlConfig {
            kp: number("MR_PID_KP", 0.9)?,
            ki: number("MR_PID_KI", 0.3)?,
            kd: number("MR_PID_KD", 0.0)?,
            deadband: number("MR_CONTROL_DEADBAND", 20.0)?,
            allocator,
        };

        Ok(Self {
            home_assistant_api: credential("MR_HOME_ASSISTANT_API")?,
            home_assistant_bearer_token: credential("MR_HOME_ASSISTANT_BEARER_TOKEN")?,
            influxdb_url: credential("MR_INFLUXDB_URL")?,
            influxdb_token: credential("MR_INFLUXDB_TOKEN")?,

            serial_device,
            serial_baud,
            serial_devices,
            meter_gone_after_ms,
            endpoints,
            inverter_host,
            inverters,
            stats_port: port("MR_STATS_PORT", 2002)?,

            discovery,
            alerts,

            web_port: port("MR_WEB_PORT", 8484)?,
            web_dir: PathBuf::from(optional("MR_WEB_DIR", "web/dist")),

            meter_target_power: number("MR_METER_TARGET_POWER", 50.0)?,
            control,
        })
    }
}

/// Splits a comma-separated environment list into trimmed, non-empty entries.
fn split_list(spec: &str) -> Vec<String> {
    spec.split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

/// Builds the plant from `MR_INVERTERS` (a comma-separated priority list) plus
/// `MR_<ID>_*` overrides for each entry.
///
/// Adding a third inverter is therefore: append its id to `MR_INVERTERS`, set
/// `MR_<ID>_DRIVER` to a known driver, and tune it with `MR_<ID>_*`. The
/// defaults below are the two-inverter plant that has been running, so an
/// unmodified environment behaves exactly as before.
fn load_inverters(
    optional: &impl Fn(&str, &str) -> String,
    number: &impl Fn(&str, f64) -> anyhow::Result<f64>,
    port: &impl Fn(&str, u16) -> anyhow::Result<u16>,
    boolean: &impl Fn(&str, bool) -> anyhow::Result<bool>,
    optional_number: &impl Fn(&str) -> anyhow::Result<Option<f64>>,
) -> anyhow::Result<Vec<InverterConfig>> {
    let list = optional("MR_INVERTERS", "solis,solax");
    let presets = AllocatorConfig::default().inverters;

    let mut out: Vec<InverterConfig> = Vec::new();
    for raw in list.split(',') {
        let id = raw.trim();
        if id.is_empty() {
            continue;
        }
        if out.iter().any(|inv| inv.id() == id) {
            return Err(anyhow!("MR_INVERTERS lists {id:?} twice"));
        }

        let prefix = format!("MR_{}", id.to_ascii_uppercase());
        let var = |suffix: &str| format!("{prefix}_{suffix}");

        // Start from the matching built-in preset if there is one, so an
        // unconfigured plant keeps its tuned values.
        let preset = presets.iter().find(|p| p.id == id);
        let mut policy = preset.cloned().unwrap_or_else(|| {
            InverterPolicy {
                name: titlecase(id),
                // Anything that is not the first entry is, by construction, part
                // of the reserve group.
                min_soc: (!out.is_empty()).then_some(15.0),
                max_soc: (!out.is_empty()).then_some(95.0),
                ..InverterPolicy::new(id, &titlecase(id))
            }
        });

        policy.id = id.to_string();
        policy.name = optional(&var("NAME"), &policy.name);
        // Which group it belongs to. Default: the first entry, which is what the
        // old "index 0 is the primary" rule meant, so a plant that never
        // mentions PRIMARY is unchanged. Two `true`s make a primary group that
        // divides the discharge demand — and the current — between its members.
        policy.primary = boolean(&var("PRIMARY"), out.is_empty())?;
        policy.max_discharge = number(&var("MAX_DISCHARGE"), policy.max_discharge)?;
        policy.max_charge = number(&var("MAX_CHARGE"), policy.max_charge)?;
        policy.slew_w_per_s = number(&var("SLEW"), policy.slew_w_per_s)?;
        policy.charge_power = number(&var("CHARGE_POWER"), policy.charge_power)?;
        policy.min_soc = match optional_number(&var("MIN_SOC"))? {
            Some(value) => Some(value),
            None => policy.min_soc,
        };
        policy.max_soc = match optional_number(&var("MAX_SOC"))? {
            Some(value) => Some(value),
            None => policy.max_soc,
        };
        policy.absorb_surplus = boolean(&var("ABSORB_SURPLUS"), policy.absorb_surplus)?;

        let driver = optional(&var("DRIVER"), id).to_ascii_lowercase();
        let defaults = driver_defaults(&driver)?;
        let dialect_name = optional(&var("METER_DIALECT"), "eem").to_ascii_lowercase();
        let meter_dialect = crate::meter::meter_dialect(&dialect_name).ok_or_else(|| {
            anyhow!(
                "{} names unknown meter dialect {dialect_name:?}; known: eem, sdm630",
                var("METER_DIALECT")
            )
        })?;
        let meter_poll = match optional(&var("METER_POLL"), "") {
            spec if spec.trim().is_empty() => driver_meter_poll(&driver),
            spec => parse_meter_poll(&spec)
                .with_context(|| format!("parsing {}", var("METER_POLL")))?,
        };
        let power_source_name = optional(&var("POWER_SOURCE"), "battery").to_ascii_lowercase();
        let power_source = inverters::power_source(&power_source_name).ok_or_else(|| {
            anyhow!(
                "{} names unknown power source {power_source_name:?}; known: battery, ac \
                 (ac = measure this inverter by its AC-port register, for a unit whose \
                 battery block is the BMS's CAN figure rather than its own measurement)",
                var("POWER_SOURCE")
            )
        })?;

        out.push(InverterConfig {
            driver: driver.clone(),
            port: port(&var("PORT"), defaults.port)?,
            slave: number(&var("SLAVE"), defaults.slave as f64)? as u8,
            kp: number(&var("KP"), defaults.kp)?,
            ki: number(&var("KI"), defaults.ki)?,
            kd: number(&var("KD"), 0.0)?,
            nudge_limit: number(&var("NUDGE_LIMIT"), defaults.nudge_limit)?,
            reverse: boolean(&var("REVERSE"), defaults.reverse)?,
            ha_prefix: optional(&var("HA_PREFIX"), defaults.ha_prefix),
            probe_regs: inverters::probe_regs(&driver)?,
            meter_poll,
            meter_dialect,
            power_source,
            policy,
        });
    }

    if out.is_empty() {
        return Err(anyhow!("MR_INVERTERS must list at least one inverter"));
    }

    // A shared port or slave address would have two inverters answering for
    // each other, which looks like working hardware and is not: catch it at
    // startup, where the message names the offender.
    for (index, inverter) in out.iter().enumerate() {
        for other in &out[index + 1..] {
            if inverter.port == other.port {
                return Err(anyhow!(
                    "inverters {:?} and {:?} share meter port {}: give one of them \
                     MR_{}_PORT",
                    inverter.id(),
                    other.id(),
                    inverter.port,
                    other.id().to_ascii_uppercase()
                ));
            }
            if inverter.slave == other.slave {
                return Err(anyhow!(
                    "inverters {:?} and {:?} share stats slave address {}: give one of \
                     them MR_{}_SLAVE",
                    inverter.id(),
                    other.id(),
                    inverter.slave,
                    other.id().to_ascii_uppercase()
                ));
            }
        }
    }

    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// Runs `load_inverters` against a literal environment.
    fn plant(vars: &[(&str, &str)]) -> anyhow::Result<Vec<InverterConfig>> {
        let map: HashMap<String, String> = vars
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();

        let get = |key: &str| map.get(key).cloned();
        let optional = |key: &str, default: &str| get(key).unwrap_or_else(|| default.to_string());
        let number = |key: &str, default: f64| -> anyhow::Result<f64> {
            match get(key) {
                Some(value) => value
                    .parse::<f64>()
                    .with_context(|| format!("{key} must be a number, got {value:?}")),
                None => Ok(default),
            }
        };
        let port = |key: &str, default: u16| -> anyhow::Result<u16> {
            match get(key) {
                Some(value) => value
                    .parse::<u16>()
                    .with_context(|| format!("{key} must be a valid port, got {value:?}")),
                None => Ok(default),
            }
        };
        let boolean = |key: &str, default: bool| -> anyhow::Result<bool> {
            match get(key) {
                Some(value) => match value.as_str() {
                    "1" | "true" | "yes" | "on" => Ok(true),
                    "0" | "false" | "no" | "off" => Ok(false),
                    _ => Err(anyhow!("{key} must be a boolean, got {value:?}")),
                },
                None => Ok(default),
            }
        };
        let optional_number = |key: &str| -> anyhow::Result<Option<f64>> {
            match get(key) {
                Some(value) => Ok(Some(value.parse::<f64>().with_context(|| {
                    format!("{key} must be a number, got {value:?}")
                })?)),
                None => Ok(None),
            }
        };

        load_inverters(&optional, &number, &port, &boolean, &optional_number)
    }

    #[test]
    fn the_default_plant_is_the_two_inverter_one() {
        let inverters = plant(&[]).expect("defaults should load");

        assert_eq!(
            inverters.iter().map(InverterConfig::id).collect::<Vec<_>>(),
            ["solis", "solax"]
        );
        assert_eq!(inverters[0].driver, "solis");
        assert_eq!(inverters[0].port, 2000);
        assert_eq!(inverters[0].slave, 2);
        assert_eq!(inverters[0].ha_prefix, "inverter");
        assert!(inverters[0].reverse);
        assert_eq!(inverters[1].driver, "solax");
        assert_eq!(inverters[1].port, 2001);
        assert_eq!(inverters[1].slave, 1);
        assert_eq!(inverters[1].ha_prefix, "solax");
        // Both banks absorb the surplus, the primary first.
        assert!(inverters[0].policy.absorb_surplus);
        assert!(inverters[1].policy.absorb_surplus);
        assert_eq!(inverters[1].policy.min_soc, Some(15.0));
        assert_eq!(inverters[1].policy.max_soc, Some(95.0));
    }

    #[test]
    fn a_third_inverter_reuses_a_driver_and_takes_its_own_overrides() {
        let inverters = plant(&[
            ("MR_INVERTERS", "solis,solax,solax2"),
            ("MR_SOLAX2_DRIVER", "solax"),
            ("MR_SOLAX2_PORT", "2003"),
            ("MR_SOLAX2_SLAVE", "3"),
            ("MR_SOLAX2_MAX_DISCHARGE", "800"),
            ("MR_SOLAX2_ABSORB_SURPLUS", "false"),
        ])
        .expect("a third inverter should configure");

        assert_eq!(inverters.len(), 3);
        let third = &inverters[2];
        assert_eq!(third.id(), "solax2");
        assert_eq!(third.driver, "solax", "drivers are reusable across inverters");
        assert_eq!(third.port, 2003);
        assert_eq!(third.slave, 3);
        assert_eq!(third.policy.max_discharge, 800.0);
        assert_eq!(third.policy.name, "Solax2");
        assert!(!third.policy.absorb_surplus, "the override wins over the default");
        // Anything it is a *reserve* by virtue of position, not by name.
        assert_eq!(third.policy.min_soc, Some(15.0));
        assert_eq!(third.policy.max_soc, Some(95.0));
        // The generic per-inverter loop defaults come from the driver.
        assert_eq!(third.kp, 0.5);
        assert!(!third.reverse);
    }

    #[test]
    fn the_existing_mr_solis_and_mr_solax_names_still_work() {
        let inverters = plant(&[
            ("MR_SOLIS_MAX_DISCHARGE", "3000"),
            ("MR_SOLAX_CHARGE_POWER", "555"),
        ])
        .expect("the legacy spellings should load");

        assert_eq!(inverters[0].policy.max_discharge, 3_000.0);
        assert_eq!(inverters[1].policy.charge_power, 555.0);
    }

    #[test]
    fn an_unknown_driver_is_a_startup_error() {
        let error = plant(&[("MR_SOLIS_DRIVER", "fronius")]).expect_err("should be rejected");
        assert!(
            error.to_string().contains("fronius"),
            "the message should name the driver: {error}"
        );
    }

    #[test]
    fn a_three_phase_inverter_selects_its_meter_dialect() {
        let inverters = plant(&[
            ("MR_INVERTERS", "solis,solax,solis2"),
            ("MR_SOLIS2_DRIVER", "solis"),
            ("MR_SOLIS2_PORT", "2003"),
            ("MR_SOLIS2_SLAVE", "3"),
            ("MR_SOLIS2_METER_DIALECT", "sdm630"),
            ("MR_SOLIS2_METER_POLL", "4:0:6,4:12:6,4:18:6,4:52:6"),
        ])
        .expect("the 2026-11-27 three-inverter plant should configure");

        assert_eq!(inverters[2].meter_dialect.name, "sdm630");
        assert_eq!(
            inverters[2].meter_poll,
            vec![(4, 0, 6), (4, 12, 6), (4, 18, 6), (4, 52, 6)]
        );
        assert_eq!(
            inverters[0].meter_dialect.name, "eem",
            "the lines that predate the S6 keep the map they were tuned against"
        );

        let error = plant(&[
            ("MR_INVERTERS", "solis,solax,solis2"),
            ("MR_SOLIS2_DRIVER", "solis"),
            ("MR_SOLIS2_METER_DIALECT", "modbus-plus"),
        ])
        .expect_err("an invented dialect must not start the plant");
        assert!(
            error.to_string().contains("modbus-plus"),
            "the message should name the dialect: {error}"
        );
    }

    #[test]
    fn two_inverters_may_not_share_a_port_or_a_slave() {
        let port = plant(&[("MR_SOLAX_PORT", "2000")]).expect_err("shared port");
        assert!(port.to_string().contains("share meter port"), "{port}");

        let slave = plant(&[("MR_SOLAX_SLAVE", "2")]).expect_err("shared slave");
        assert!(slave.to_string().contains("share stats slave"), "{slave}");
    }

    #[test]
    fn a_duplicate_id_is_rejected() {
        let error = plant(&[("MR_INVERTERS", "solis,solax,solis")]).expect_err("duplicate id");
        assert!(error.to_string().contains("twice"), "{error}");
    }

    #[test]
    fn the_driver_defaults_carry_the_discovery_fingerprints() {
        let inverters = plant(&[]).expect("defaults should load");

        assert_eq!(inverters[0].probe_regs, (4, 33149));
        assert_eq!(inverters[0].meter_poll, vec![(4, 0, 76), (4, 342, 2)]);
        assert_eq!(inverters[1].probe_regs, (4, 0x02));
        assert_eq!(
            inverters[1].meter_poll,
            vec![(4, 12, 2), (3, 11, 1), (4, 74, 2)]
        );
    }

    #[test]
    fn a_second_inverter_on_the_same_driver_shares_its_fingerprint() {
        let inverters = plant(&[
            ("MR_INVERTERS", "solis,solax,solax2"),
            ("MR_SOLAX2_DRIVER", "solax"),
            ("MR_SOLAX2_PORT", "2003"),
            ("MR_SOLAX2_SLAVE", "3"),
        ])
        .expect("a third inverter should configure");

        // Two Solaxes are indistinguishable by listening; startup discovery
        // falls back to the configured ports for exactly this case.
        assert_eq!(inverters[2].meter_poll, inverters[1].meter_poll);
        assert_eq!(inverters[2].port, 2003);
    }

    #[test]
    fn a_meter_poll_override_teaches_discovery_a_new_driver() {
        let inverters = plant(&[
            ("MR_INVERTERS", "solis,solax"),
            ("MR_SOLAX_METER_POLL", "4:99:1,3:11:1"),
        ])
        .expect("the override should parse");

        assert_eq!(inverters[1].meter_poll, vec![(4, 99, 1), (3, 11, 1)]);
        // The other inverter is untouched.
        assert_eq!(inverters[0].meter_poll, vec![(4, 0, 76), (4, 342, 2)]);
    }

    #[test]
    fn a_malformed_meter_poll_override_is_a_startup_error() {
        // `anyhow`'s Display prints the outermost context only, so the useful
        // part of the chain has to be read with the debug format.
        let error = plant(&[("MR_SOLAX_METER_POLL", "4:99")]).expect_err("should be rejected");
        let chain = format!("{error:?}");
        assert!(chain.contains("parsing MR_SOLAX_METER_POLL"), "{chain}");
        assert!(chain.contains("fc:register:count"), "{chain}");

        let error = plant(&[("MR_SOLAX_METER_POLL", "4:x:1")]).expect_err("should be rejected");
        let chain = format!("{error:?}");
        assert!(chain.contains("must be a number"), "{chain}");
    }

    #[test]
    fn meter_poll_specs_round_trip_through_the_parser() {
        assert_eq!(
            parse_meter_poll(" 4:342:2 , 4:0:76 ").unwrap(),
            vec![(4, 342, 2), (4, 0, 76)]
        );
        assert!(parse_meter_poll("").is_err());
        assert!(parse_meter_poll("4:0:76,4:1:1:1").is_err());
        assert!(parse_meter_poll("300:0:1").is_err());
    }

    #[test]
    fn discovery_defaults_are_auto_and_strict() {
        let defaults = DiscoverySettings::default();
        assert_eq!(defaults.mode, DiscoveryMode::Auto);
        assert!(defaults.mode.enabled());
        assert!(defaults.strict, "an unverified line must not be driven by default");
        assert!(defaults.attempts >= 1);
        assert!(
            defaults.listen_ms >= 2_000,
            "a Solis polls at about 1 Hz, so a short window would see nothing"
        );
        assert_eq!(DiscoveryMode::Off.as_str(), "off");
        assert!(!DiscoveryMode::Off.enabled());
    }
}
