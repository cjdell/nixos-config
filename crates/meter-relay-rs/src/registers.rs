use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::Duration;

use crate::parser::{ModbusRequest, ModbusResponse};
use crate::transport::ModbusSlaveGroup;
use crate::util::now_ms;

/// Thread-safe cache of 16-bit Modbus registers, keyed by function code then
/// register address. Scheduled polls fill it; synchronous getters read it.
#[derive(Default)]
pub struct RegisterCache {
    map: RwLock<HashMap<u8, HashMap<u16, u16>>>,
    /// When each register was last written, so a device that stops answering
    /// can be told apart from one reporting zero.
    updated: RwLock<HashMap<u8, HashMap<u16, u64>>>,
}

impl RegisterCache {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn store_response(&self, res: &ModbusResponse) {
        let now = now_ms();
        let mut map = self.map.write().unwrap();
        let mut updated = self.updated.write().unwrap();
        let registers = map.entry(res.request.function_code).or_default();
        let stamps = updated.entry(res.request.function_code).or_default();
        for i in 0..res.request.num_regs as usize {
            let offset = i * 2;
            if offset + 2 > res.regs.len() {
                break;
            }
            let address = res.request.start_reg.wrapping_add(i as u16);
            let value = u16::from_be_bytes([res.regs[offset], res.regs[offset + 1]]);
            registers.insert(address, value);
            stamps.insert(address, now);
        }
    }

    fn raw(&self, function_code: u8, address: u16) -> Option<u16> {
        self.map
            .read()
            .unwrap()
            .get(&function_code)
            .and_then(|registers| registers.get(&address).copied())
    }

    pub fn contains(&self, function_code: u8, address: u16) -> bool {
        self.raw(function_code, address).is_some()
    }

    /// True when this register was written within the last `max_age_ms`.
    pub fn is_fresh(&self, function_code: u8, address: u16, max_age_ms: u64) -> bool {
        let updated = self.updated.read().unwrap();
        match updated
            .get(&function_code)
            .and_then(|registers| registers.get(&address).copied())
        {
            Some(at) => now_ms().saturating_sub(at) <= max_age_ms,
            None => false,
        }
    }

    pub fn read_i16(&self, function_code: u8, address: u16) -> f64 {
        self.raw(function_code, address).unwrap_or(0) as i16 as f64
    }

    pub fn read_i32(&self, function_code: u8, address: u16) -> f64 {
        let high = self.raw(function_code, address).unwrap_or(0) as u32;
        let low = self.raw(function_code, address.wrapping_add(1)).unwrap_or(0) as u32;
        (((high << 16) | low) as i32) as f64
    }

    pub fn read_f32(&self, function_code: u8, address: u16) -> f64 {
        let high = self.raw(function_code, address).unwrap_or(0) as u32;
        let low = self.raw(function_code, address.wrapping_add(1)).unwrap_or(0) as u32;
        f32::from_bits((high << 16) | low) as f64
    }

    /// Builds a response payload for `req` from cached words, zero-filling
    /// anything we have not seen yet.
    pub fn fill(&self, req: &ModbusRequest) -> Vec<u8> {
        let mut out = vec![0u8; req.num_regs as usize * 2];
        for i in 0..req.num_regs as usize {
            if let Some(value) = self.raw(req.function_code, req.start_reg.wrapping_add(i as u16)) {
                out[i * 2..i * 2 + 2].copy_from_slice(&value.to_be_bytes());
            }
        }
        out
    }
}

#[derive(Clone, Copy)]
pub struct RegDef {
    pub function_code: u8,
    pub address: u16,
    pub num_regs: u16,
    pub interval_ms: u64,
}

/// Periodically polls a set of register definitions into a [`RegisterCache`].
pub struct ModbusSlaveProxy {
    group: Arc<ModbusSlaveGroup>,
    slave_address: u8,
    cache: Arc<RegisterCache>,
    defs: &'static [RegDef],
}

impl ModbusSlaveProxy {
    pub fn new(
        group: Arc<ModbusSlaveGroup>,
        slave_address: u8,
        cache: Arc<RegisterCache>,
        defs: &'static [RegDef],
    ) -> Arc<Self> {
        Arc::new(Self {
            group,
            slave_address,
            cache,
            defs,
        })
    }

    pub fn init(self: &Arc<Self>) {
        for &def in self.defs {
            let proxy = Arc::clone(self);
            tokio::spawn(async move {
                loop {
                    let req = ModbusRequest::new(
                        proxy.slave_address,
                        def.function_code,
                        def.address,
                        def.num_regs,
                    );
                    match proxy.group.send_request(req).await {
                        Ok(res) => proxy.cache.store_response(&res),
                        Err(err) => tracing::debug!(
                            slave = proxy.slave_address,
                            "scheduled register poll failed: {err}"
                        ),
                    }
                    tokio::time::sleep(Duration::from_millis(def.interval_ms)).await;
                }
            });
        }
    }
}
