use chrono::{Local, NaiveTime};
use std::time::{SystemTime, UNIX_EPOCH};

/// CRC-16/MODBUS, matching the TypeScript implementation exactly.
pub fn crc16(data: &[u8]) -> u16 {
    let mut crc: u16 = 0xffff;
    for &byte in data {
        crc ^= byte as u16;
        for _ in 0..8 {
            let odd = crc & 0x0001;
            crc >>= 1;
            if odd != 0 {
                crc ^= 0xa001;
            }
        }
    }
    crc
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn is_within_time_range(start: &str, end: &str) -> bool {
    let parse = |s: &str| NaiveTime::parse_from_str(s, "%H:%M").unwrap_or_default();
    let now = Local::now().time();
    let start = parse(start);
    let end = parse(end);
    now >= start && now <= end
}

/// Octopus Go cheap window: 00:30 - 05:29 local time.
pub fn is_octopus_go_time_range() -> bool {
    is_within_time_range("00:30", "05:29")
}

pub fn read_f32_be(buf: &[u8], byte_index: usize) -> f32 {
    f32::from_bits(u32::from_be_bytes([
        buf[byte_index],
        buf[byte_index + 1],
        buf[byte_index + 2],
        buf[byte_index + 3],
    ]))
}

pub fn write_f32_be(buf: &mut [u8], byte_index: usize, value: f32) {
    buf[byte_index..byte_index + 4].copy_from_slice(&value.to_bits().to_be_bytes());
}
