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

/// One meter *dialect*: the register layout the emulated meter speaks on one
/// meter line.
///
/// The registers whose flow values default to **zero** when their freshness
/// window lapses — the power *flow* is the measurement the plant acts on,
/// and the one that must never be served frozen. Everything else on the
/// meter line keeps its last believable value on purpose: zeroing an energy
/// *counter* is a reset-lie worse than a slow one, and zeroing apparent or
/// reactive power while active power is non-zero is physically impossible —
/// a V=0/0A/45W meter is exactly what a Solis cross-check flags as
/// `Meter Select Fail` (fault 8217, measured 2026-11-27). In the general
/// case the same rule is carried by [`MeterDialect::current`] /
/// [`MeterDialect::active_power`].
///
/// The grid measurement is single-phase and lives once in the cache (voltage
/// at [`R_VOLTAGE`], current at [`R_CURRENT`], active power at
/// [`R_ACTIVE_POWER`], …). A dialect says where each quantity appears **in
/// the inverter's address space** — identity for the EEM-style map the two
/// original lines were tuned against, and mirrors/totals for a three-phase
/// dialect like the S6 Solis's Eastron SDM630 map (per-phase voltages at
/// 0/2/4, per-phase active power at 12/14/16, totals at 52/56/60), where the
/// single measured value is replicated per phase and every position that
/// carries active power is a legal point for the PID nudge.
#[derive(Clone, Copy, Debug)]
pub struct MeterDialect {
    pub name: &'static str,
    /// f32 start positions of each quantity in the inverter's space.
    pub voltage: &'static [u16],
    pub current: &'static [u16],
    pub active_power: &'static [u16],
    pub apparent_power: &'static [u16],
    pub reactive_power: &'static [u16],
    /// Cumulative energy counter positions: never zeroed on staleness, like
    /// every counter (a reset counter is a lie worse than a slow one).
    pub energy: &'static [u16],
    /// Power-factor positions. Only a dialect whose totals are derived from
    /// the substituted watts fills these, and it fills them with 1.00.
    pub power_factor: &'static [u16],
    /// Serve a meter that is internally consistent for an inverter which
    /// *validates* it: apparent power follows the substituted active power,
    /// reactive power is zero and PF is 1.00 — a purely resistive device.
    ///
    /// This is not cosmetic. The S6 cross-checks its meter, and when the
    /// nudge grew past the house's real kVA the totals said "1580 W through
    /// 0 VA at PF 0.00"; it discarded the meter (`Meter Select Fail` is the
    /// latching form of the same check, see [`EEM`]) and its meter block read
    /// zero from then on, leaving the unit to charge on its own policy. The
    /// grid meter's own VA/VAR are measured against a *different* active
    /// power than the one we substitute, so they cannot be reused once the
    /// nudge is large. The historical EEM line is left exactly as it was —
    /// its inverter has never applied the check and its values are
    /// regression-tested byte-for-byte.
    pub consistent_totals: bool,
    /// Extra positions filled by copying a cache register that does not sit
    /// at that position itself: `(inverter position, cache register)`. For
    /// SDM630 these are the L2/L3 mirrors and the totals block.
    pub copies: &'static [(u16, u16)],
}

/// The map the plant was built against: single-phase EEM/Eastron SDM120-230
/// style — V@0, I@6, P@12, S@18, Q@24, import@72, total@342.
pub const EEM: MeterDialect = MeterDialect {
    name: "eem",
    voltage: &[R_VOLTAGE],
    current: &[R_CURRENT],
    active_power: &[R_ACTIVE_POWER],
    apparent_power: &[R_APPARENT_POWER],
    reactive_power: &[R_REACTIVE_POWER],
    energy: &[R_IMPORT_ACTIVE_ENERGY, R_TOTAL_ACTIVE_ENERGY],
    power_factor: &[],
    consistent_totals: false,
    copies: &[],
};

/// Eastron SDM630 three-phase input-register map, as polled by newer Solis
/// hybrids (measured 2026-11-27 on the second Solis's meter line: it asks
/// for `fc4 0x00 n6` (phase volts), `fc4 0x0C n6` (per-phase active power),
/// `fc4 0x18 n6` (per-phase reactive) and `fc4 0x34 n6` (the totals block —
/// total active power at 52), the last at ~100 Hz while no meter answers).
/// One measured three-phase aggregate is honest as long as every position
/// says the same thing: each phase mirrors L1, each total reads the cache,
/// so a bulk read is internally consistent and matches what an inverter
/// cross-checks (sum of phases == total).
pub const SDM630: MeterDialect = MeterDialect {
    name: "sdm630",
    voltage: &[0, 2, 4],
    current: &[6, 8, 10],
    active_power: &[12, 52],
    // The Eastron SDM630 totals block is consecutive 4-byte floats:
    // 52 total W, 54 total VA, 56 total VAR, 58 total PF, 60 phase angle.
    // The earlier map used a 4-register stride (S@56, Q@60), which put the
    // grid meter's apparent power in the VAR slot and the reactive power in
    // the angle slot — three of the four totals wrong at once.
    apparent_power: &[18, 54],
    reactive_power: &[24, 56],
    energy: &[72, 74, 342],
    power_factor: &[58],
    consistent_totals: true,
    copies: &[(2, 0), (4, 0), (8, 6), (10, 6), (52, 12), (54, 18), (56, 24)],
};

pub fn meter_dialect(name: &str) -> Option<&'static MeterDialect> {
    match name {
        "eem" => Some(&EEM),
        "sdm630" => Some(&SDM630),
        _ => None,
    }
}

impl MeterDialect {
    /// The cache register behind a position in the inverter's space: the
    /// position itself unless a copy fills it from elsewhere.
    fn cache_reg(&self, position: u16) -> u16 {
        self.copies
            .iter()
            .find(|(to, _)| *to == position)
            .map_or(position, |(_, from)| *from)
    }

    /// Whether a position of this dialect carries grid active power — the
    /// quantity the PID nudge rides on and the flow that defaults to zero
    /// when stale.
    pub fn is_active_power(&self, position: u16) -> bool {
        self.active_power.contains(&position)
    }

    pub fn is_current(&self, position: u16) -> bool {
        self.current.contains(&position)
    }

    pub fn is_apparent_power(&self, position: u16) -> bool {
        self.apparent_power.contains(&position)
    }

    pub fn is_reactive_power(&self, position: u16) -> bool {
        self.reactive_power.contains(&position)
    }

    pub fn is_power_factor(&self, position: u16) -> bool {
        self.power_factor.contains(&position)
    }

    fn is_negated(&self, position: u16) -> bool {
        // Apparent and reactive power are magnitudes: negating them on a
        // reversed line produces a meter that reports negative VA, which is
        // one more thing a cross-checking inverter can reject. Only the
        // signed quantities — active power and current — flip.
        self.is_current(position) || self.is_active_power(position)
    }

    fn known(&self, position: u16) -> bool {
        self.voltage.contains(&position)
            || self.current.contains(&position)
            || self.active_power.contains(&position)
            || self.apparent_power.contains(&position)
            || self.reactive_power.contains(&position)
            || self.power_factor.contains(&position)
            || self.energy.contains(&position)
            || self.copies.iter().any(|(to, _)| *to == position)
    }
}

/// What the emulated line serves for grid voltage when this process has
/// *never* received one (the first fraction of a second after every restart,
/// while the serial meter is still being polled for the first time): a
/// believable mains voltage, because "0 V" while the per-inverter PID is
/// already nudging non-zero watts is the impossible combination that makes
/// the inverters distrust the meter wholesale (see [`MeterDialect`] and
/// the fault-8217 notes on [`EEM`]).
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

    pub fn build_response(&self, req: &ModbusRequest, dialect: &MeterDialect) -> ModbusResponse {
        let mut regs = self.cache.fill(req);
        if req.function_code == METER_FUNCTION_CODE {
            // Dialect mirrors and totals: a three-phase line must say the
            // same thing about the same grid everywhere it is read.
            for (to, from) in dialect.copies {
                if *to >= req.start_reg && *to + 1 < req.start_reg + req.num_regs {
                    let value = self.cache.read_f32(METER_FUNCTION_CODE, *from) as f32;
                    write_f32_be(&mut regs, (*to - req.start_reg) as usize * 2, value);
                }
            }
            // A dead flow reading must not be served frozen — at every
            // position of the dialect that carries it.
            for positions in [dialect.current, dialect.active_power] {
                for register in positions {
                    let cache_reg = dialect.cache_reg(*register);
                    let fits = *register >= req.start_reg && *register + 1 < req.start_reg + req.num_regs;
                    if fits && !self.is_fresh(cache_reg) {
                        let byte_index = (*register - req.start_reg) as usize * 2;
                        write_f32_be(&mut regs, byte_index, 0.0);
                    }
                }
            }
            // Cold boot: a never-measured voltage must not reach an inverter
            // as 0.00 V while the nudges are already non-zero watts — see
            // DEFAULT_GRID_VOLTAGE. A stale-but-known voltage just keeps
            // serving its last believable value (not in STALE_ZEROED).
            if self
                .cache
                .last_update(METER_FUNCTION_CODE, R_VOLTAGE)
                .is_none()
            {
                for register in dialect.voltage {
                    if *register >= req.start_reg && *register + 1 < req.start_reg + req.num_regs {
                        let byte_index = (*register - req.start_reg) as usize * 2;
                        write_f32_be(&mut regs, byte_index, DEFAULT_GRID_VOLTAGE);
                    }
                }
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
        dialect: &MeterDialect,
    ) {
        if res.request.slave_address != 1 || res.request.function_code != METER_FUNCTION_CODE {
            return;
        }

        for (register, byte_index) in res.request.registers() {
            if !dialect.known(register) {
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

            if reverse && dialect.is_negated(register) {
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
        let mut res = meter.build_response(&req, &EEM);
        meter.modify_response(&mut res, true, None, &EEM);
        assert_eq!(read_float(&res.regs), -1234.0);
    }

    #[test]
    fn override_replaces_active_power() {
        let meter = setup();
        let req = ModbusRequest::new(1, 4, R_ACTIVE_POWER, 2);
        let mut res = meter.build_response(&req, &EEM);

        let override_fn = |register: u16, _value: f64| -> f64 {
            if register == R_ACTIVE_POWER {
                50.0
            } else {
                0.0
            }
        };

        meter.modify_response(&mut res, false, Some(&override_fn), &EEM);
        assert_eq!(read_float(&res.regs), 50.0);
    }

    #[test]
    fn unknown_slave_is_left_untouched() {
        let meter = setup();
        let req = ModbusRequest::new(2, 4, R_ACTIVE_POWER, 2);
        let mut res = meter.build_response(&req, &EEM);
        meter.modify_response(&mut res, true, None, &EEM);
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

        let power = meter.build_response(&ModbusRequest::new(1, 4, R_ACTIVE_POWER, 2), &EEM);
        assert_eq!(
            read_float(&power.regs),
            0.0,
            "a dead measurement must not be served frozen"
        );
        let current = meter.build_response(&ModbusRequest::new(1, 4, R_CURRENT, 2), &EEM);
        assert_eq!(read_float(&current.regs), 0.0);

        // Voltage is deliberately not zeroed: the inverters should keep
        // believing the grid is there — only the flow nobody measured
        // defaults to zero.
        let voltage = meter.build_response(&ModbusRequest::new(1, 4, R_VOLTAGE, 2), &EEM);
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
        let cold = meter.build_response(&ModbusRequest::new(1, 4, 0, 76), &EEM);
        assert_eq!(read_float(&cold.regs), DEFAULT_GRID_VOLTAGE);

        // Energy is a cumulative counter: staleness keeps the last believable
        // value rather than resetting it to zero in front of the inverter.
        cache.store_response(&ModbusResponse::from_regs(
            ModbusRequest::new(1, 4, R_TOTAL_ACTIVE_ENERGY, 2),
            (12345.0f32).to_bits().to_be_bytes().to_vec(),
        ));
        cache.mark_age(METER_FUNCTION_CODE, R_TOTAL_ACTIVE_ENERGY, 31_000);
        let res = meter.build_response(&ModbusRequest::new(1, 4, R_TOTAL_ACTIVE_ENERGY, 2), &EEM);
        assert_eq!(
            read_float(&res.regs),
            12345.0,
            "a stale counter stays put — resetting it is the worse lie"
        );
    }
}

#[cfg(test)]
mod dialect_tests {
    use super::*;
    use crate::parser::{ModbusRequest, ModbusResponse};

    /// Cache seeded with one honest single-phase set of readings: 230 V,
    /// 10 A, 800 W, 1234 VA, 300 var — the values an SDM630 line must
    /// replicate everywhere, consistently.
    fn setup() -> Arc<Meter> {
        let cache = Arc::new(RegisterCache::new());
        let store = |address: u16, value: f32| {
            let req = ModbusRequest::new(1, 4, address, 2);
            cache.store_response(&ModbusResponse::from_regs(
                req,
                value.to_bits().to_be_bytes().to_vec(),
            ));
        };
        store(R_VOLTAGE, 230.0);
        store(R_CURRENT, 10.0);
        store(R_ACTIVE_POWER, 800.0);
        store(R_APPARENT_POWER, 1234.0);
        store(R_REACTIVE_POWER, 300.0);
        Meter::new(cache)
    }

    fn floats(regs: &[u8]) -> Vec<f32> {
        regs.as_chunks::<4>()
            .0
            .iter()
            .map(|w| f32::from_bits(u32::from_be_bytes(*w)))
            .collect()
    }

    /// The f32 sitting at inverter-space register `reg` inside a response
    /// that starts at `start`.
    fn f(regs: &[u8], start: u16, reg: u16) -> f32 {
        let i = ((reg - start) as usize) * 2;
        f32::from_bits(u32::from_be_bytes([
            regs[i],
            regs[i + 1],
            regs[i + 2],
            regs[i + 3],
        ]))
    }

    #[test]
    fn sdm630_totals_read_the_cache_from_the_eem_positions() {
        let meter = setup();
        // The S6's totals poll (fc4 0x34 n10) is the Eastron layout: 52 total
        // W, 54 total VA, 56 total VAR. The earlier 4-register stride guess
        // (S@56, Q@60) put the meter's VA in the VAR slot and its VAR in the
        // phase-angle slot, which is one of the reasons the S6 stopped
        // trusting the emulated meter once the nudge grew.
        let res = meter.build_response(&ModbusRequest::new(1, 4, 52, 10), &SDM630);
        assert_eq!(f(&res.regs, 52, 52), 800.0);
        assert_eq!(f(&res.regs, 52, 54), 1234.0);
        assert_eq!(f(&res.regs, 52, 56), 300.0);
    }

    #[test]
    fn sdm630_mirrors_every_phase_from_the_one_measurement() {
        let meter = setup();
        let volts = meter.build_response(&ModbusRequest::new(1, 4, 0, 6), &SDM630);
        assert_eq!(floats(&volts.regs), vec![230.0, 230.0, 230.0]);
        let amps = meter.build_response(&ModbusRequest::new(1, 4, 6, 6), &SDM630);
        assert_eq!(floats(&amps.regs), vec![10.0, 10.0, 10.0]);
        // Per-phase active power (fc4 0x0C n6): L1 carries the reading, and
        // the untouched L2/L3 words read zero — sum == total, which is what
        // the inverter cross-checks.
        let watts = meter.build_response(&ModbusRequest::new(1, 4, 12, 6), &SDM630);
        assert_eq!(floats(&watts.regs), vec![800.0, 0.0, 0.0]);
        // A bulk read must be consistent the same way: every position that
        // carries a quantity says the same number as its cache twin.
        let bulk = meter.build_response(&ModbusRequest::new(1, 4, 0, 62), &SDM630);
        assert_eq!(f(&bulk.regs, 0, 12), f(&bulk.regs, 0, 52));
        assert_eq!(f(&bulk.regs, 0, 18), f(&bulk.regs, 0, 54));
        assert_eq!(f(&bulk.regs, 0, 24), f(&bulk.regs, 0, 56));
        assert_eq!(f(&bulk.regs, 0, 0), f(&bulk.regs, 0, 4));
    }

    #[test]
    fn sdm630_zeroes_flow_at_every_position_of_the_dialect() {
        let meter = setup();
        meter
            .cache
            .mark_age(METER_FUNCTION_CODE, R_ACTIVE_POWER, 5_001);
        meter
            .cache
            .mark_age(METER_FUNCTION_CODE, R_CURRENT, 30_001);
        let res = meter.build_response(&ModbusRequest::new(1, 4, 0, 60), &SDM630);
        let f = |reg: u16| floats(&res.regs[(reg as usize) * 2..(reg as usize) * 2 + 4])[0];
        for reg in [6u16, 8, 10, 12, 52] {
            assert_eq!(f(reg), 0.0, "stale flow must read zero at {reg}");
        }
        // Voltage and counters keep their believable values (8217 lesson).
        assert_eq!(f(0), 230.0);
    }

    #[test]
    fn sdm630_cold_boot_seeds_every_phase_voltage() {
        let meter = Meter::new(Arc::new(RegisterCache::new()));
        let res = meter.build_response(&ModbusRequest::new(1, 4, 0, 60), &SDM630);
        let f = |reg: u16| floats(&res.regs[(reg as usize) * 2..(reg as usize) * 2 + 4])[0];
        for reg in [0u16, 2, 4] {
            assert_eq!(f(reg), DEFAULT_GRID_VOLTAGE, "no 0.00 V on a cold boot");
        }
    }

    #[test]
    fn nudge_and_reverse_land_on_the_dialect_positions() {
        let meter = setup();
        // An S6 line reads total power at 52; the nudge and the (unverified)
        // reverse flag must act there, not on 12.
        let mut res = meter.build_response(&ModbusRequest::new(1, 4, 52, 2), &SDM630);
        let nudge = |_reg: u16, _value: f64| -> f64 { 650.0 };
        meter.modify_response(&mut res, false, Some(&nudge), &SDM630);
        assert_eq!(floats(&res.regs), vec![650.0]);

        let mut res = meter.build_response(&ModbusRequest::new(1, 4, 52, 2), &SDM630);
        meter.modify_response(&mut res, true, None, &SDM630);
        assert_eq!(floats(&res.regs), vec![-800.0]);
    }
}
