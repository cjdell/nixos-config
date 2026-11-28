//! Raw Modbus passthrough on the stats bus (`GET`/`POST /api/modbus`).
//!
//! The relay owns the stats bus for the whole process lifetime, so every
//! diagnostic read and every one-off register change used to mean stopping the
//! service, waiting for ser2net to release the port, and starting it again —
//! which also drops the emulated meter lines and costs the plant its setpoint
//! while you are looking at it.
//!
//! Requests here ride the lane the poll loop already owns: `ModbusSlaveGroup`
//! serialises everything behind one lock, so an ad-hoc read lands between two
//! polls and changes nothing else. Reads are always allowed. Writes are gated
//! by `MR_MODBUS_WRITE_ENABLED` — a raw FC6 can change an inverter's storage
//! mode, which is how the S6's latched meter rejection was cleared, and it is
//! not something a stray LAN request should be able to do by accident.

use std::sync::Arc;

use serde::Deserialize;
use serde_json::{json, Value};

use crate::parser::ModbusRequest;
use crate::transport::ModbusSlaveGroup;

/// One Modbus read is capped at 125 registers by the spec; the largest block
/// this plant polls is 76.
pub const MAX_COUNT: u16 = 125;

#[derive(Debug, Deserialize)]
pub struct ModbusCall {
    /// `read` or `write`.
    pub op: String,
    pub slave: u8,
    /// 3 or 4 for a read. Ignored for a write, which is always FC6.
    #[serde(default)]
    pub function: u8,
    pub address: u16,
    /// Registers to read. Ignored for a write.
    #[serde(default = "one")]
    pub count: u16,
    /// Value to write (FC6).
    pub value: Option<u16>,
}

#[derive(Debug, Deserialize)]
pub struct ModbusQuery {
    pub slave: u8,
    pub address: u16,
    #[serde(default = "one")]
    pub count: u16,
    #[serde(default = "four")]
    pub function: u8,
}

fn one() -> u16 {
    1
}

fn four() -> u8 {
    4
}

/// A validated request. Validation is pure so the rules are testable without a
/// bus — this endpoint is reachable from the LAN and must not be able to emit
/// a frame no device expects.
#[derive(Debug, PartialEq, Eq)]
pub enum Call {
    Read {
        slave: u8,
        function: u8,
        address: u16,
        count: u16,
    },
    Write {
        slave: u8,
        address: u16,
        value: u16,
    },
}

impl ModbusCall {
    pub fn validate(self) -> Result<Call, String> {
        check_slave(self.slave)?;
        match self.op.as_str() {
            "read" => {
                check_read(self.function, self.address, self.count)?;
                Ok(Call::Read {
                    slave: self.slave,
                    function: self.function,
                    address: self.address,
                    count: self.count,
                })
            }
            "write" => {
                let value = self.value.ok_or("a write needs a value")?;
                check_range(self.address, 1)?;
                Ok(Call::Write {
                    slave: self.slave,
                    address: self.address,
                    value,
                })
            }
            other => Err(format!("op must be read or write, got {other:?}")),
        }
    }
}

impl ModbusQuery {
    pub fn validate(self) -> Result<Call, String> {
        check_slave(self.slave)?;
        check_read(self.function, self.address, self.count)?;
        Ok(Call::Read {
            slave: self.slave,
            function: self.function,
            address: self.address,
            count: self.count,
        })
    }
}

fn check_slave(slave: u8) -> Result<(), String> {
    if slave == 0 || slave > 247 {
        return Err(format!("slave must be 1..=247, got {slave}"));
    }
    Ok(())
}

fn check_read(function: u8, address: u16, count: u16) -> Result<(), String> {
    if function != 3 && function != 4 {
        return Err(format!("read function must be 3 or 4, got {function}"));
    }
    check_range(address, count)
}

fn check_range(address: u16, count: u16) -> Result<(), String> {
    if count == 0 || count > MAX_COUNT {
        return Err(format!("count must be 1..={MAX_COUNT}, got {count}"));
    }
    if u32::from(address) + u32::from(count) > 65_536 {
        return Err(format!("{address} + {count} runs past the register space"));
    }
    Ok(())
}

pub struct RawModbus {
    group: Arc<ModbusSlaveGroup>,
    write_enabled: bool,
}

impl RawModbus {
    pub fn new(group: Arc<ModbusSlaveGroup>, write_enabled: bool) -> Arc<Self> {
        Arc::new(Self {
            group,
            write_enabled,
        })
    }

    pub async fn run(&self, call: Call) -> Result<Value, String> {
        let started = std::time::Instant::now();
        match call {
            Call::Read {
                slave,
                function,
                address,
                count,
            } => {
                let response = self
                    .group
                    .send_request(ModbusRequest::new(slave, function, address, count))
                    .await?;
                let mut registers = Vec::with_capacity(count as usize);
                for i in 0..count as usize {
                    let at = i * 2;
                    registers.push(if at + 2 <= response.regs.len() {
                        u16::from_be_bytes([response.regs[at], response.regs[at + 1]])
                    } else {
                        0
                    });
                }
                Ok(json!({
                    "ok": true,
                    "op": "read",
                    "slave": slave,
                    "function": function,
                    "address": address,
                    "count": count,
                    "registers": registers,
                    "elapsed_ms": started.elapsed().as_millis() as u64,
                }))
            }
            Call::Write {
                slave,
                address,
                value,
            } => {
                if !self.write_enabled {
                    return Err("writes are disabled (MR_MODBUS_WRITE_ENABLED)".into());
                }
                let ack = self.group.write_register(slave, address, value).await?;
                // `confirmed` is the part to read: a Solis writes the register
                // before it answers (measured: the FC6 echo times out on every
                // storage-mode change), so an echo is not the evidence — the
                // read-back is. A caller that retried on "unacknowledged" would
                // double-apply a write that had in fact landed.
                Ok(json!({
                    "ok": ack.confirmed(),
                    "op": "write",
                    "slave": slave,
                    "address": address,
                    "value": value,
                    "echoed": ack.echoed,
                    "value_now": ack.value_now,
                    "confirmed": ack.confirmed(),
                    "elapsed_ms": started.elapsed().as_millis() as u64,
                }))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(slave: u8, function: u8, address: u16, count: u16) -> ModbusCall {
        ModbusCall {
            op: "read".into(),
            slave,
            function,
            address,
            count,
            value: None,
        }
    }

    #[test]
    fn a_read_accepts_only_the_two_read_function_codes() {
        assert!(read(3, 4, 43600, 8).validate().is_ok());
        assert!(read(3, 3, 43110, 1).validate().is_ok());
        for fc in [1u8, 2, 5, 6, 15, 16] {
            assert!(read(3, fc, 43110, 1).validate().is_err(), "fc {fc}");
        }
    }

    #[test]
    fn a_read_cannot_ask_for_more_than_the_spec_allows_or_wrap() {
        assert!(read(3, 4, 0, MAX_COUNT).validate().is_ok());
        assert!(read(3, 4, 0, 0).validate().is_err());
        assert!(read(3, 4, 0, MAX_COUNT + 1).validate().is_err());
        assert!(read(3, 4, 65_530, 10).validate().is_err());
    }

    #[test]
    fn a_slave_address_must_be_a_real_one() {
        assert!(read(0, 4, 0, 1).validate().is_err());
        assert!(read(248, 4, 0, 1).validate().is_err());
        assert!(read(3, 4, 0, 1).validate().is_ok());
    }

    #[test]
    fn a_write_needs_a_value_and_ignores_count_and_function() {
        let call = ModbusCall {
            op: "write".into(),
            slave: 3,
            function: 0,
            address: 43110,
            count: 99,
            value: Some(1),
        };
        assert_eq!(
            call.validate().unwrap(),
            Call::Write {
                slave: 3,
                address: 43110,
                value: 1
            }
        );

        let no_value = ModbusCall {
            op: "write".into(),
            slave: 3,
            function: 0,
            address: 43110,
            count: 1,
            value: None,
        };
        assert!(no_value.validate().is_err());
    }

    #[test]
    fn an_unknown_op_is_refused() {
        let call = ModbusCall {
            op: "scan".into(),
            slave: 3,
            function: 4,
            address: 0,
            count: 1,
            value: None,
        };
        assert!(call.validate().is_err());
    }
}
