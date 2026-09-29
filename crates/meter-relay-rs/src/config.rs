use std::net::IpAddr;
use std::path::PathBuf;

use anyhow::{anyhow, bail, Context};

use crate::allocation::{AllocatorConfig, InverterPolicy};
use crate::control::ControlConfig;
use crate::endpoint::{self, Endpoint};
use crate::inverters;

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
    /// Every local serial candidate, always at least the configured device.
    /// More than one lets discovery find the meter if a second USB adapter
    /// enumerates ahead of it.
    pub serial_devices: Vec<Endpoint>,
    /// An explicit remote candidate list (`MR_ENDPOINTS`), if one was given.
    /// Empty means "derive the candidates from the ports below".
    pub endpoints: Vec<Endpoint>,
    pub inverter_host: String,
    /// The plant, in priority order: index 0 is the primary actuator.
    pub inverters: Vec<InverterConfig>,
    /// Shared socket both inverters are polled on for telemetry registers.
    pub stats_port: u16,

    /// How startup works out which endpoint is which. See `discovery.rs`.
    pub discovery: DiscoverySettings,

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

        // Serial candidates. The grid meter is a local USB device whose stable
        // path is the configured default; naming several lets discovery find it
        // if a second adapter ever enumerates ahead of it.
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
            endpoints,
            inverter_host,
            inverters,
            stats_port: port("MR_STATS_PORT", 2002)?,

            discovery,

            web_port: port("MR_WEB_PORT", 8484)?,
            web_dir: PathBuf::from(optional("MR_WEB_DIR", "web/dist")),

            meter_target_power: number("MR_METER_TARGET_POWER", 50.0)?,
            control,
        })
    }
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
        let meter_poll = match optional(&var("METER_POLL"), "") {
            spec if spec.trim().is_empty() => driver_meter_poll(&driver),
            spec => parse_meter_poll(&spec)
                .with_context(|| format!("parsing {}", var("METER_POLL")))?,
        };

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
