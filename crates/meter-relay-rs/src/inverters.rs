use std::sync::Arc;

use anyhow::anyhow;

use crate::registers::{RegDef, RegisterCache};

/// Minimal interface the control machinery needs from an inverter.
pub trait Inverter: Send + Sync {
    /// Positive = discharging, negative = charging.
    fn battery_power(&self) -> f64;

    /// What the control loops actually measure this inverter by: the battery
    /// register, unless the driver was built with [`PowerSource::Ac`] because
    /// its battery block is not a measurement of itself. Same sign convention
    /// either way — **positive = discharging** — so the loops' feedback stays
    /// negative when a plant switches source.
    fn control_power(&self) -> f64 {
        self.battery_power()
    }
}

/// Which of a unit's own registers the control loops measure it by.
///
/// `Battery` is the historical one and correct wherever the battery block is
/// the inverter's own shunt. `Ac` exists for a hybrid whose battery block is
/// the BMS's CAN figure instead: the second Solis reports the *bank's* current
/// as its own, so a per-inverter loop driven by it sees the other inverters'
/// work as its own error and corrects at twice the needed gain — measured
/// overnight 2026-11-28 as ±3.9 kW swings at that unit's AC port with a ~66 s
/// period, dragging the plant's grid flow between 1.6 and 8.6 kW. Its AC port
/// is the honest signal, and for this unit it is also the complete one: no PV
/// strings and no load on its output, so every watt at the AC port is a watt
/// to or from the battery (less ~8 % conversion).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PowerSource {
    /// The inverter's battery power register ([`SOLIS_BATTERY_POWER_REGS`], …).
    #[default]
    Battery,
    /// The inverter's own AC-port power register ([`SOLIS_INVERTING_POWER_REGS`]).
    Ac,
}

pub fn power_source(name: &str) -> Option<PowerSource> {
    match name {
        "battery" => Some(PowerSource::Battery),
        "ac" => Some(PowerSource::Ac),
        _ => None,
    }
}

pub const SOLIS_REGS: &[RegDef] = &[
    RegDef { function_code: 4, address: 33095, num_regs: 1, interval_ms: 10_000 }, // Status
    RegDef { function_code: 4, address: 33133, num_regs: 1, interval_ms: 10_000 }, // BatteryVoltage
    RegDef { function_code: 4, address: 33057, num_regs: 2, interval_ms: 500 }, // SolarPower
    RegDef { function_code: 4, address: 33051, num_regs: 1, interval_ms: 500 }, // SolarVoltage2
    RegDef { function_code: 4, address: 33073, num_regs: 1, interval_ms: 500 }, // PhaseAVoltage
    RegDef { function_code: 4, address: 33147, num_regs: 1, interval_ms: 1_000 }, // LoadPower
    RegDef { function_code: 4, address: 33135, num_regs: 1, interval_ms: 10_000 }, // BatteryStatus
    RegDef { function_code: 4, address: 33149, num_regs: 2, interval_ms: 500 }, // BatteryPower
    // The inverter's AC-port flow: "+ to grid, - from grid". This is the one
    // power figure a unit measures itself even when its battery block is fed
    // from the BMS over CAN (the S6 does exactly that — see docs/meter-relay.md).
    RegDef { function_code: 4, address: 33151, num_regs: 2, interval_ms: 500 }, // InvertingPower
];

/// Function code and start address of the Solis battery power register
/// (signed, positive = discharging). Used for freshness checks.
pub const SOLIS_BATTERY_POWER_REGS: (u8, u16) = (4, 33149);

/// Function code and start address of the Solis AC-port power register (signed
/// 32-bit, `+` = to grid, `-` = from grid). The control measurement of a unit
/// built on [`PowerSource::Ac`]; used for freshness checks.
pub const SOLIS_INVERTING_POWER_REGS: (u8, u16) = (4, 33151);

pub const SOLAX_REGS: &[RegDef] = &[
    RegDef { function_code: 4, address: 0x02, num_regs: 1, interval_ms: 200 }, // Power
    RegDef { function_code: 4, address: 0x1c, num_regs: 1, interval_ms: 10_000 }, // Percentage
];

/// Function code and start address of the Solax power register (signed,
/// positive = discharging). Used for freshness checks.
pub const SOLAX_POWER_REGS: (u8, u16) = (4, 0x02);

/// Function code and start address of the Solax state-of-charge register.
pub const SOLAX_PERCENTAGE_REGS: (u8, u16) = (4, 0x1c);

/// What one inverter reads right now.
///
/// Every optional field is a register this make/model does not have (or has
/// gone stale), not a zero: a Solax reports only battery power and state of
/// charge, and publishing `0.0` for its array voltage would be a lie the
/// dashboard then has to explain.
#[derive(Clone, Debug, Default)]
pub struct InverterReadings {
    /// Positive = discharging, negative = charging.
    pub battery_power: f64,
    pub solar_power: Option<f64>,
    pub battery_voltage: Option<f64>,
    pub solar_voltage: Option<f64>,
    pub ac_voltage: Option<f64>,
    pub load_power: Option<f64>,
    /// The inverter's own AC-port power (W): `+` = to grid (discharge),
    /// `-` = from grid (charge). Unlike `battery_power`, this is measured by
    /// the unit itself even on models whose battery block mirrors the BMS.
    pub inverting_power: Option<f64>,
    pub percentage: Option<f64>,
    pub status: Option<String>,
}

/// A make/model of inverter.
///
/// The control law and the allocator know nothing about these; the controller
/// holds each one behind this trait, so the plant's size is a configuration
/// matter. The only trait method the *control* path needs is
/// [`Inverter::battery_power`]; the rest describe how to poll the device and
/// what to show on the dashboard.
pub trait InverterDriver: Inverter + Send + Sync {
    /// Registers to poll into this inverter's cache.
    fn telemetry_regs(&self) -> &'static [RegDef];

    /// The register whose freshness means "this device is reporting" — the one
    /// the control loop reads power from. Must follow
    /// [`Inverter::control_power`]: gating a register the loop does not read
    /// means freezing on a live signal or trusting a dead one.
    fn power_regs(&self) -> (u8, u16);

    /// Whether this make/model has an AC-port register at all, i.e. whether
    /// `MR_<ID>_POWER_SOURCE=ac` can be honored. Checked at startup so a plant
    /// that asks for a measurement the device cannot give fails loudly instead
    /// of quietly measuring something else.
    fn supports_ac_power(&self) -> bool {
        false
    }

    /// The state-of-charge register, for a device that has one. `None` means
    /// the device does not report SOC at all, so the allocator applies no floor
    /// or ceiling to it.
    fn soc_regs(&self) -> Option<(u8, u16)>;

    /// A snapshot for the dashboard.
    fn readings(&self) -> InverterReadings;
}

/// Builds the driver for a configured inverter.
///
/// **Adding an inverter model means adding an arm here** (and, if it needs
/// retuning rather than the generic defaults, a row in `driver_defaults()` in
/// `config.rs`). Everything else — the allocator, the control law, telemetry,
/// the dashboard — is already sized by the plant list.
pub fn build(
    driver: &str,
    cache: Arc<RegisterCache>,
    source: PowerSource,
) -> anyhow::Result<Arc<dyn InverterDriver>> {
    match driver {
        "solis" => Ok(SolisInverter::new(cache, source) as Arc<dyn InverterDriver>),
        // The Solax's only power register is its battery-side one, so a plant
        // that asks for `ac` here is refused at startup by
        // `InverterDriver::supports_ac_power`.
        "solax" => Ok(SolaxInverter::new(cache) as Arc<dyn InverterDriver>),
        other => Err(anyhow!(
            "unknown inverter driver {other:?}: add it to inverters::build()"
        )),
    }
}

/// The register a discovery probe can read to prove this driver is present.
///
/// Startup discovery deliberately does not build a driver to ask this — a
/// driver needs a register cache and an answer already — so the answer lives
/// here beside the register maps it belongs to. An inverter that answers its
/// own power register is on the stats bus; it is the one thing that tells that
/// bus apart from the meter lines, which never answer a slave request.
pub fn probe_regs(driver: &str) -> anyhow::Result<(u8, u16)> {
    match driver {
        "solis" => Ok(SOLIS_BATTERY_POWER_REGS),
        "solax" => Ok(SOLAX_POWER_REGS),
        other => Err(anyhow!(
            "unknown inverter driver {other:?}: add it to inverters::build()"
        )),
    }
}

pub struct SolisInverter {
    cache: Arc<RegisterCache>,
    /// Which register the control loops measure this unit by, and therefore
    /// which one the freshness gate watches. See [`PowerSource`].
    source: PowerSource,
}

impl SolisInverter {
    pub fn new(cache: Arc<RegisterCache>, source: PowerSource) -> Arc<Self> {
        Arc::new(Self { cache, source })
    }

    pub fn get_status(&self) -> String {
        inverter_status(self.cache.read_i16(4, 33095) as i32).to_string()
    }

    pub fn get_battery_voltage(&self) -> f64 {
        self.cache.read_i16(4, 33133) / 10.0
    }

    pub fn get_solar_power(&self) -> f64 {
        self.cache.read_i32(4, 33057)
    }

    pub fn get_solar_voltage2(&self) -> f64 {
        self.cache.read_i16(4, 33051) / 10.0
    }

    pub fn get_phase_a_voltage(&self) -> f64 {
        self.cache.read_i16(4, 33073) / 10.0
    }

    /// Always positive.
    pub fn get_load_power(&self) -> f64 {
        self.cache.read_i16(4, 33147)
    }

    /// The inverter's own AC-port power: `+` to grid, `-` from grid.
    pub fn get_inverting_power(&self) -> f64 {
        self.cache.read_i32(4, 33151)
    }
}

impl Inverter for SolisInverter {
    fn battery_power(&self) -> f64 {
        let status = self.cache.read_i16(4, 33135) as i32;
        let power = self.cache.read_i32(4, 33149);
        // Positive = discharging, negative = charging. Treat any unexpected
        // status as discharging rather than panicking.
        match status {
            0 => -power,
            1 => power,
            _ => power,
        }
    }

    fn control_power(&self) -> f64 {
        match self.source {
            PowerSource::Battery => self.battery_power(),
            // Deliberately NOT run through the status-word negation above:
            // 33135 describes the battery side, and 33151 carries its own sign
            // ("+" to grid). Applying both would turn this unit's feedback
            // positive — with a 1500 W nudge behind it that is a runaway, not a
            // control loop. The convention the loops rely on is "positive =
            // discharging"; the tests in this module pin both sources to agree
            // on it for one physical flow.
            PowerSource::Ac => self.get_inverting_power(),
        }
    }
}

impl InverterDriver for SolisInverter {
    fn telemetry_regs(&self) -> &'static [RegDef] {
        SOLIS_REGS
    }

    fn power_regs(&self) -> (u8, u16) {
        match self.source {
            PowerSource::Battery => SOLIS_BATTERY_POWER_REGS,
            PowerSource::Ac => SOLIS_INVERTING_POWER_REGS,
        }
    }

    fn supports_ac_power(&self) -> bool {
        true
    }

    fn soc_regs(&self) -> Option<(u8, u16)> {
        // The Solis has no state-of-charge register; the pack's SOC comes from
        // the BMS in Home Assistant, not from this device.
        None
    }

    fn readings(&self) -> InverterReadings {
        InverterReadings {
            battery_power: self.battery_power(),
            solar_power: Some(self.get_solar_power()),
            battery_voltage: Some(self.get_battery_voltage()),
            solar_voltage: Some(self.get_solar_voltage2()),
            ac_voltage: Some(self.get_phase_a_voltage()),
            load_power: Some(self.get_load_power()),
            inverting_power: Some(self.get_inverting_power()),
            // The Solis has no state-of-charge register; the pack's SOC comes
            // from the BMS in Home Assistant, not from this device.
            percentage: None,
            status: Some(self.get_status()),
        }
    }
}

pub struct SolaxInverter {
    cache: Arc<RegisterCache>,
}

impl SolaxInverter {
    pub fn new(cache: Arc<RegisterCache>) -> Arc<Self> {
        Arc::new(Self { cache })
    }

    /// Positive = discharging, negative = charging.
    pub fn get_percentage(&self) -> f64 {
        self.cache.read_i16(4, 0x1c)
    }
}

impl Inverter for SolaxInverter {
    fn battery_power(&self) -> f64 {
        self.cache.read_i16(4, 0x02)
    }
}

impl InverterDriver for SolaxInverter {
    fn telemetry_regs(&self) -> &'static [RegDef] {
        SOLAX_REGS
    }

    fn power_regs(&self) -> (u8, u16) {
        SOLAX_POWER_REGS
    }

    fn soc_regs(&self) -> Option<(u8, u16)> {
        Some(SOLAX_PERCENTAGE_REGS)
    }

    fn readings(&self) -> InverterReadings {
        InverterReadings {
            battery_power: self.battery_power(),
            percentage: Some(self.get_percentage()),
            // This device exposes nothing else through the stats socket.
            ..InverterReadings::default()
        }
    }
}

pub fn inverter_status(code: i32) -> &'static str {
    match code {
        0 => "Waiting",
        1 => "Open Operating",
        2 => "Soft Run",
        3 => "Generating",
        4 => "Bypass Inverter Running",
        5 => "Bypass Inverter Sync",
        6 => "Bypass Grid Running",
        15 => "Normal Running",
        4100 => "Grid Off",
        61456 => "Grid Surge",
        61457 => "Fan Fault",
        4112 => "Grid Overvoltage",
        4113 => "Grid Undervoltage",
        4114 => "Grid Overfrequency",
        4115 => "Grid Underfrequency",
        4116 => "Grid Reverse Current",
        4117 => "No-Grid",
        4118 => "Grid Unbalanced",
        4119 => "Grid Frequency Fluctuation",
        4120 => "Grid Overcurrent",
        4121 => "Grid Current Sampling Error (1)",
        4128 => "DC Overvoltage",
        4129 => "DC Bus Overvoltage",
        4130 => "DC Bus Unbalanced",
        4131 => "DC Bus Undervoltage",
        4132 => "DC Bus Unbalanced 2",
        4133 => "DC(Channel A) Overcurrent",
        4134 => "DC(Channel B) Overcurrent",
        4135 => "DC Interference",
        4136 => "DC Reverse",
        4137 => "PV Midpoint Grounding",
        4144 => "Grid Interference Protection",
        4145 => "DSP Inital Protection",
        4146 => "Over Temperature Protection",
        4147 => "PV Insulation Fault",
        4148 => "Leakage Current Protection",
        4149 => "Relay Check Protection",
        4150 => "DSP_B Protection",
        4151 => "DC Injection Protection",
        4152 => "12V Undervoltage Faulty",
        4153 => "Leakage Current Check Protection",
        4154 => "Under Temperature Protection",
        4160 => "AFCI Check Fault",
        4161 => "AFCI Fault",
        4162 => "DSP Chip SRAM Fault",
        4163 => "DSP Chip FLASH Fault",
        4164 => "DSP Chip PC Pointer Fault",
        4165 => "DSP Chip Register Fault",
        4166 => "Grid Interference Protection 02",
        4167 => "Grid Current Sampling Error (2)",
        4168 => "IGBT Overcurrent",
        4176 => "Grid Transient Overcurrent",
        4177 => "Battery Hardware Overvoltage fault",
        4178 => "LLC Hardware Overcurrent",
        4179 => "Battery Overvoltage",
        4180 => "Battery Undervoltage",
        4181 => "Battery Not Connected",
        4182 => "Backup Overvoltage",
        4183 => "Backup Overload",
        4184 => "DSP Selfcheck Error",
        8208 => "Fail Safe",
        8209 => "Meter COM Fail",
        8210 => "Battery COM Fail",
        8212 => "DSP COM Fail",
        8213 => "BMS Alarm",
        8214 => "BatName-FAIL",
        8215 => "BMS Alarm 2",
        8216 => "DRM Connect Fail",
        8217 => "Meter Select Fail",
        8224 => "Lead-acid Battery High Temp",
        8225 => "Lead-acid Battery Low Temp",
        _ => "Unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{ModbusRequest, ModbusResponse};

    /// Fills a cache with single fc4 words, as the stats poll would.
    fn cache_with(words: &[(u16, u16)]) -> Arc<RegisterCache> {
        let cache = Arc::new(RegisterCache::new());
        for (address, value) in words {
            let request = ModbusRequest::new(3, 4, *address, 1);
            cache.store_response(&ModbusResponse::from_regs(
                request,
                value.to_be_bytes().to_vec(),
            ));
        }
        cache
    }

    /// Adds one signed 32-bit fc4 register pair (the Solis power registers).
    fn store_i32(cache: &RegisterCache, address: u16, value: i32) {
        let request = ModbusRequest::new(3, 4, address, 2);
        cache.store_response(&ModbusResponse::from_regs(
            request,
            value.to_be_bytes().to_vec(),
        ));
    }

    /// The convention every control loop is written against: positive =
    /// discharging. A unit that reports the same physical flow on both
    /// registers must therefore produce the same sign from either source —
    /// otherwise selecting `ac` would flip a loop's feedback positive.
    #[test]
    fn both_control_sources_agree_on_the_sign_of_one_physical_flow() {
        // Charging: battery status 0 with a positive magnitude register, and
        // the AC port reporting "from grid".
        let cache = cache_with(&[(33135, 0)]);
        store_i32(&cache, 33149, 6_000.0 as i32);
        store_i32(&cache, 33151, -6_000);
        let battery = SolisInverter::new(Arc::clone(&cache), PowerSource::Battery);
        let ac = SolisInverter::new(cache, PowerSource::Ac);
        assert!(battery.control_power() < 0.0 && ac.control_power() < 0.0);
        assert_eq!(battery.control_power(), ac.control_power());

        // Discharging: status 1, and the AC port reporting "to grid".
        let cache = cache_with(&[(33135, 1)]);
        store_i32(&cache, 33149, 6_000);
        store_i32(&cache, 33151, 6_000);
        let battery = SolisInverter::new(Arc::clone(&cache), PowerSource::Battery);
        let ac = SolisInverter::new(cache, PowerSource::Ac);
        assert!(battery.control_power() > 0.0 && ac.control_power() > 0.0);
        assert_eq!(battery.control_power(), ac.control_power());
    }

    /// The battery register's sign depends on the status word; the AC-port
    /// register carries its own. Applying the status negation to the AC value
    /// as well would measure the opposite of what it says.
    #[test]
    fn the_ac_source_is_not_run_through_the_status_word_negation() {
        let cache = cache_with(&[(33135, 0)]);
        store_i32(&cache, 33149, 6_000);
        store_i32(&cache, 33151, 6_000);
        let ac = SolisInverter::new(cache, PowerSource::Ac);
        assert_eq!(
            ac.battery_power(),
            -6_000.0,
            "status 0 negates the battery register"
        );
        assert_eq!(
            ac.control_power(),
            6_000.0,
            "and the AC register must keep its own sign"
        );
    }

    /// Freshness must gate the register the loop reads: a unit whose battery
    /// block went dead must not look alive because its AC port is answering.
    #[test]
    fn the_freshness_gate_follows_the_selected_source() {
        let cache = cache_with(&[]);
        assert_eq!(
            SolisInverter::new(Arc::clone(&cache), PowerSource::Battery).power_regs(),
            SOLIS_BATTERY_POWER_REGS
        );
        assert_eq!(
            SolisInverter::new(cache, PowerSource::Ac).power_regs(),
            SOLIS_INVERTING_POWER_REGS
        );
    }

    #[test]
    fn power_source_names_are_parsed_explicitly() {
        assert_eq!(power_source("battery"), Some(PowerSource::Battery));
        assert_eq!(power_source("ac"), Some(PowerSource::Ac));
        assert_eq!(power_source("inverting"), None);
        assert_eq!(PowerSource::default(), PowerSource::Battery);
    }
}
