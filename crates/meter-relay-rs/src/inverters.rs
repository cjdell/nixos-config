use std::sync::Arc;

use anyhow::anyhow;

use crate::registers::{RegDef, RegisterCache};

/// Minimal interface the control machinery needs from an inverter.
pub trait Inverter: Send + Sync {
    /// Positive = discharging, negative = charging.
    fn battery_power(&self) -> f64;
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
];

/// Function code and start address of the Solis battery power register
/// (signed, positive = discharging). Used for freshness checks.
pub const SOLIS_BATTERY_POWER_REGS: (u8, u16) = (4, 33149);

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
    /// the control loop reads power from.
    fn power_regs(&self) -> (u8, u16);

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
pub fn build(driver: &str, cache: Arc<RegisterCache>) -> anyhow::Result<Arc<dyn InverterDriver>> {
    match driver {
        "solis" => Ok(SolisInverter::new(cache) as Arc<dyn InverterDriver>),
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
}

impl SolisInverter {
    pub fn new(cache: Arc<RegisterCache>) -> Arc<Self> {
        Arc::new(Self { cache })
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
}

impl InverterDriver for SolisInverter {
    fn telemetry_regs(&self) -> &'static [RegDef] {
        SOLIS_REGS
    }

    fn power_regs(&self) -> (u8, u16) {
        SOLIS_BATTERY_POWER_REGS
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
