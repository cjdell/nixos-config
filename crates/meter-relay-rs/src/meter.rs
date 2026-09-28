use std::sync::Arc;

use crate::parser::{ModbusRequest, ModbusResponse};
use crate::registers::{RegDef, RegisterCache};
use crate::util::{read_f32_be, write_f32_be};

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
    RegDef { function_code: 4, address: R_VOLTAGE, num_regs: 2, interval_ms: 10_000 },
    RegDef { function_code: 4, address: R_CURRENT, num_regs: 2, interval_ms: 10_000 },
    RegDef { function_code: 4, address: R_ACTIVE_POWER, num_regs: 2, interval_ms: 50 },
    RegDef { function_code: 4, address: R_APPARENT_POWER, num_regs: 2, interval_ms: 10_000 },
    RegDef { function_code: 4, address: R_REACTIVE_POWER, num_regs: 2, interval_ms: 10_000 },
    RegDef { function_code: 4, address: R_IMPORT_ACTIVE_ENERGY, num_regs: 2, interval_ms: 10_000 },
    RegDef { function_code: 4, address: R_TOTAL_ACTIVE_ENERGY, num_regs: 2, interval_ms: 10_000 },
    RegDef { function_code: 4, address: R_BULK, num_regs: 76, interval_ms: 10_000 },
    RegDef { function_code: 3, address: R_SYSTEM_TYPE, num_regs: 1, interval_ms: 10_000 },
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
        self.cache.read_f32(METER_FUNCTION_CODE, R_ACTIVE_POWER)
    }

    pub fn get_voltage(&self) -> f64 {
        self.cache.read_f32(METER_FUNCTION_CODE, R_VOLTAGE)
    }

    pub fn build_response(&self, req: &ModbusRequest) -> ModbusResponse {
        let regs = self.cache.fill(req);
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
}
