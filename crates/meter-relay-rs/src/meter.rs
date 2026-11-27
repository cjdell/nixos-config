use std::sync::Arc;

use crate::parser::{ModbusRequest, ModbusResponse};
use crate::registers::{RegDef, RegisterCache};
use crate::util::{now_ms, read_f32_be, write_f32_be};

// Grid meter register addresses (function code 4 unless noted).
pub const R_VOLTAGE: u16 = 0;
pub const R_CURRENT: u16 = 6;
pub const R_ACTIVE_POWER: u16 = 12;
pub const R_APPARENT_POWER: u16 = 18;
pub const R_REACTIVE_POWER: u16 = 24;
pub const R_IMPORT_ACTIVE_ENERGY: u16 = 72;
pub const R_TOTAL_ACTIVE_ENERGY: u16 = 342;
pub const R_BULK: u16 = 0;
pub const R_SYSTEM_TYPE: u16 = 11;

const METER_FUNCTION_CODE: u8 = 4;

/// Floor for every register's staleness window, so the 50 ms power poll is
/// judged on missed polls rather than on serial jitter (see
/// [`stale_window_ms`]).
const METER_STALE_FLOOR_MS: u64 = 5_000;

/// The registers that default to **0** when their freshness window lapses:
/// the power *flow* — the measurement the plant acts on, and the one the
/// user asked to default to zero rather than freeze. Everything else on the
/// meter line keeps its last believable value on purpose: zeroing an energy
/// *counter* is a reset-lie worse than a slow one, and zeroing apparent or
/// reactive power while active power is non-zero is physically impossible —
/// a V=0/0A/45W meter is exactly what a Solis cross-check flags as
/// `Meter Select Fail` (fault 8217, measured 2026-11-27).
const STALE_ZEROED: &[u16] = &[R_CURRENT, R_ACTIVE_POWER];

/// What the emulated line serves for grid voltage when this process has
/// *never* received one (the first fraction of a second after every restart,
/// while the serial meter is still being polled for the first time): a
/// believable mains voltage, because "0 V" while the per-inverter PID is
/// already nudging non-zero watts is the impossible combination that makes
/// the inverters distrust the meter wholesale (see [`STALE_ZEROED`]).
const DEFAULT_GRID_VOLTAGE: f32 = 230.0;

/// Freshness window of one meter register: three full polling periods of the
/// most-often-polled definition that covers it, floored at
/// [`METER_STALE_FLOOR_MS`]. The active-power register is therefore stale
/// after 5 s of silence (it polls every 50 ms), and the 10 s registers after
/// 30 s — three missed polls either way.
fn stale_window_ms(address: u16) -> u64 {
    let interval = METER_REGS
        .iter()
        .filter(|def| {
            def.function_code == METER_FUNCTION_CODE
                && (def.address..def.address + def.num_regs).contains(&address)
        })
        .map(|def| def.interval_ms)
        .min()
        .unwrap_or(10_000);
    (interval * 3).max(METER_STALE_FLOOR_MS)
}

/// Registers whose (float) values are rewritten for the inverters.
fn is_known_register(register: u16) -> bool {
    matches!(
        register,
        R_VOLTAGE
            | R_CURRENT
            | R_ACTIVE_POWER
            | R_APPARENT_POWER
            | R_REACTIVE_POWER
            | R_IMPORT_ACTIVE_ENERGY
            | R_TOTAL_ACTIVE_ENERGY
            | R_SYSTEM_TYPE
    )
}

pub const METER_REGS: &[RegDef] = &[
    RegDef {
        function_code: 4,
        address: R_VOLTAGE,
        num_regs: 2,
        interval_ms: 10_000,
    },
    RegDef {
        function_code: 4,
        address: R_CURRENT,
        num_regs: 2,
        interval_ms: 10_000,
    },
    RegDef {
        function_code: 4,
        address: R_ACTIVE_POWER,
        num_regs: 2,
        interval_ms: 50,
    },
    RegDef {
        function_code: 4,
        address: R_APPARENT_POWER,
        num_regs: 2,
        interval_ms: 10_000,
    },
    RegDef {
        function_code: 4,
        address: R_REACTIVE_POWER,
        num_regs: 2,
        interval_ms: 10_000,
    },
    RegDef {
        function_code: 4,
        address: R_IMPORT_ACTIVE_ENERGY,
        num_regs: 2,
        interval_ms: 10_000,
    },
    RegDef {
        function_code: 4,
        address: R_TOTAL_ACTIVE_ENERGY,
        num_regs: 2,
        interval_ms: 10_000,
    },
    RegDef {
        function_code: 4,
        address: R_BULK,
        num_regs: 76,
        interval_ms: 10_000,
    },
    RegDef {
        function_code: 3,
        address: R_SYSTEM_TYPE,
        num_regs: 1,
        interval_ms: 10_000,
    },
];

/// A view over the grid meter's cached registers that can build and rewrite
/// Modbus responses before they are handed to an inverter.
pub struct Meter {
    cache: Arc<RegisterCache>,
}

impl Meter {
    pub fn new(cache: Arc<RegisterCache>) -> Arc<Self> {
        Arc::new(Self { cache })
    }

    pub fn get_active_power(&self) -> f64 {
        if self.is_fresh(R_ACTIVE_POWER) {
            self.cache.read_f32(METER_FUNCTION_CODE, R_ACTIVE_POWER)
        } else {
            0.0
        }
    }

    /// Whether this meter register's last measurement is still trustworthy.
    pub fn is_fresh(&self, address: u16) -> bool {
        self.cache
            .is_fresh(METER_FUNCTION_CODE, address, stale_window_ms(address))
    }

    /// Whether the grid measurement the control loop balances against is
    /// fresh — which is what the control loop holds on when it is not.
    pub fn feed_fresh(&self) -> bool {
        self.is_fresh(R_ACTIVE_POWER)
    }

    /// How long ago the active-power register was last refreshed (`None`:
    /// never in this process). The alerting ages its grace off this.
    pub fn feed_age_ms(&self) -> Option<u64> {
        self.cache
            .last_update(METER_FUNCTION_CODE, R_ACTIVE_POWER)
            .map(|at| now_ms().saturating_sub(at))
    }

    pub fn get_voltage(&self) -> f64 {
        self.cache.read_f32(METER_FUNCTION_CODE, R_VOLTAGE)
    }

    pub fn build_response(&self, req: &ModbusRequest) -> ModbusResponse {
        let mut regs = self.cache.fill(req);
        if req.function_code == METER_FUNCTION_CODE {
            for register in STALE_ZEROED {
                let fits =
                    req.start_reg <= *register && register + 1 < req.start_reg + req.num_regs;
                if fits && !self.is_fresh(*register) {
                    let byte_index = (*register - req.start_reg) as usize * 2;
                    write_f32_be(&mut regs, byte_index, 0.0);
                }
            }
            // Cold boot: a never-measured voltage must not reach an inverter
            // as 0.00 V while the nudges are already non-zero watts — see
            // DEFAULT_GRID_VOLTAGE. A stale-but-known voltage just keeps
            // serving its last believable value (not in STALE_ZEROED).
            if req.start_reg == R_VOLTAGE
                && req.num_regs >= 2
                && self
                    .cache
                    .last_update(METER_FUNCTION_CODE, R_VOLTAGE)
                    .is_none()
            {
                write_f32_be(&mut regs, 0, DEFAULT_GRID_VOLTAGE);
            }
        }
        ModbusResponse::from_regs(req.clone(), regs)
    }

    /// Rewrites a response in place: the `override_fn` may perturb an active
    /// power register (via PID nudge), and `reverse` negates the power/current
    /// registers for the inverter that expects a reversed meter.
    pub fn modify_response(
        &self,
        res: &mut ModbusResponse,
        reverse: bool,
        override_fn: Option<&dyn Fn(u16, f64) -> f64>,
    ) {
        if res.request.slave_address != 1 || res.request.function_code != METER_FUNCTION_CODE {
            return;
        }

        for (register, byte_index) in res.request.registers() {
            if !is_known_register(register) {
                continue;
            }
            if byte_index + 4 > res.regs.len() {
                continue;
            }

            let value = read_f32_be(&res.regs, byte_index) as f64;

            let mut new_value = value;
            if let Some(override_fn) = override_fn {
                new_value = override_fn(register, value);
            }

            if reverse
                && matches!(
                    register,
                    R_ACTIVE_POWER | R_CURRENT | R_APPARENT_POWER | R_REACTIVE_POWER
                )
            {
                new_value = -new_value;
            }

            write_f32_be(&mut res.regs, byte_index, new_value as f32);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{ModbusRequest, ModbusResponse};

    fn read_float(regs: &[u8]) -> f32 {
        f32::from_bits(u32::from_be_bytes([regs[0], regs[1], regs[2], regs[3]]))
    }

    fn setup() -> Arc<Meter> {
        let cache = Arc::new(RegisterCache::new());

        let voltage = ModbusRequest::new(1, 4, R_VOLTAGE, 2);
        cache.store_response(&ModbusResponse::from_regs(
            voltage,
            (240.0f32).to_bits().to_be_bytes().to_vec(),
        ));

        let active = ModbusRequest::new(1, 4, R_ACTIVE_POWER, 2);
        cache.store_response(&ModbusResponse::from_regs(
            active,
            (1234.0f32).to_bits().to_be_bytes().to_vec(),
        ));

        Meter::new(cache)
    }

    #[test]
    fn reverse_negates_active_power() {
        let meter = setup();
        let req = ModbusRequest::new(1, 4, R_ACTIVE_POWER, 2);
        let mut res = meter.build_response(&req);
        meter.modify_response(&mut res, true, None);
        assert_eq!(read_float(&res.regs), -1234.0);
    }

    #[test]
    fn override_replaces_active_power() {
        let meter = setup();
        let req = ModbusRequest::new(1, 4, R_ACTIVE_POWER, 2);
        let mut res = meter.build_response(&req);

        let override_fn = |register: u16, _value: f64| -> f64 {
            if register == R_ACTIVE_POWER {
                50.0
            } else {
                0.0
            }
        };

        meter.modify_response(&mut res, false, Some(&override_fn));
        assert_eq!(read_float(&res.regs), 50.0);
    }

    #[test]
    fn unknown_slave_is_left_untouched() {
        let meter = setup();
        let req = ModbusRequest::new(2, 4, R_ACTIVE_POWER, 2);
        let mut res = meter.build_response(&req);
        meter.modify_response(&mut res, true, None);
        assert_eq!(read_float(&res.regs), 1234.0);
    }

    #[test]
    fn stale_electrical_readings_default_to_zero_while_voltage_stays_put() {
        let cache = Arc::new(RegisterCache::new());
        let meter = Meter::new(Arc::clone(&cache));
        let store = |address: u16, value: f32| {
            let req = ModbusRequest::new(1, 4, address, 2);
            cache.store_response(&ModbusResponse::from_regs(
                req,
                value.to_bits().to_be_bytes().to_vec(),
            ));
        };
        store(R_VOLTAGE, 240.0);
        store(R_ACTIVE_POWER, -2300.0);
        store(R_CURRENT, 9.0);

        assert!(meter.feed_fresh());
        assert_eq!(meter.get_active_power(), -2300.0);

        // Three missed 50 ms polls (floored at 5 s) is enough to call the
        // power measurement dead; current's own polls run at 10 s, so it
        // needs its own window to lapse.
        cache.mark_age(METER_FUNCTION_CODE, R_ACTIVE_POWER, 5_001);
        cache.mark_age(METER_FUNCTION_CODE, R_CURRENT, 30_001);
        assert!(!meter.feed_fresh());
        assert_eq!(meter.get_active_power(), 0.0);
        assert!(meter.feed_age_ms().unwrap() > 5_000);

        let power = meter.build_response(&ModbusRequest::new(1, 4, R_ACTIVE_POWER, 2));
        assert_eq!(
            read_float(&power.regs),
            0.0,
            "a dead measurement must not be served frozen"
        );
        let current = meter.build_response(&ModbusRequest::new(1, 4, R_CURRENT, 2));
        assert_eq!(read_float(&current.regs), 0.0);

        // Voltage is deliberately not zeroed: the inverters should keep
        // believing the grid is there — only the flow nobody measured
        // defaults to zero.
        let voltage = meter.build_response(&ModbusRequest::new(1, 4, R_VOLTAGE, 2));
        assert_eq!(read_float(&voltage.regs), 240.0);
        assert_eq!(meter.get_voltage(), 240.0);
    }

    #[test]
    fn staleness_windows_are_three_polls_with_a_five_second_floor() {
        assert_eq!(stale_window_ms(R_ACTIVE_POWER), METER_STALE_FLOOR_MS);
        assert_eq!(stale_window_ms(R_VOLTAGE), 30_000);
        assert_eq!(stale_window_ms(R_IMPORT_ACTIVE_ENERGY), 30_000);
        assert_eq!(stale_window_ms(R_TOTAL_ACTIVE_ENERGY), 30_000);
    }

    #[test]
    fn a_cold_boot_never_serves_a_dead_meter_and_counters_never_reset() {
        let cache = Arc::new(RegisterCache::new());
        let meter = Meter::new(Arc::clone(&cache));
        // The Solis polls its whole meter window within ~2 s of a relay
        // restart. With nothing measured yet, the line must still read like
        // a meter on a live grid — never "45 W at 0.00 V", the impossible
        // combination measured to latch a Solis Meter Select Fail.
        let cold = meter.build_response(&ModbusRequest::new(1, 4, 0, 76));
        assert_eq!(read_float(&cold.regs), DEFAULT_GRID_VOLTAGE);

        // Energy is a cumulative counter: staleness keeps the last believable
        // value rather than resetting it to zero in front of the inverter.
        cache.store_response(&ModbusResponse::from_regs(
            ModbusRequest::new(1, 4, R_TOTAL_ACTIVE_ENERGY, 2),
            (12345.0f32).to_bits().to_be_bytes().to_vec(),
        ));
        cache.mark_age(METER_FUNCTION_CODE, R_TOTAL_ACTIVE_ENERGY, 31_000);
        let res = meter.build_response(&ModbusRequest::new(1, 4, R_TOTAL_ACTIVE_ENERGY, 2));
        assert_eq!(
            read_float(&res.regs),
            12345.0,
            "a stale counter stays put — resetting it is the worse lie"
        );
    }
}
