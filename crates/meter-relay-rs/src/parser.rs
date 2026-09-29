use crate::util::crc16;

pub const FUNC_READ_HOLDING: u8 = 3;
pub const FUNC_READ_INPUT: u8 = 4;

const MIN_PACKET_LENGTH: usize = 4;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModbusRequest {
    pub slave_address: u8,
    pub function_code: u8,
    pub start_reg: u16,
    pub num_regs: u16,
}

impl ModbusRequest {
    pub fn new(slave_address: u8, function_code: u8, start_reg: u16, num_regs: u16) -> Self {
        Self {
            slave_address,
            function_code,
            start_reg,
            num_regs,
        }
    }

    pub fn parse(packet: &[u8]) -> Result<Self, String> {
        if packet.len() != 8 {
            return Err(format!(
                "ModbusRequest: packet length must be 8 bytes: {}",
                hex(packet)
            ));
        }

        let slave_address = packet[0];
        if slave_address != 1 && slave_address != 2 {
            return Err(format!(
                "ModbusRequest: slave address must be 1 or 2, got {slave_address}"
            ));
        }

        let function_code = packet[1];
        if function_code != FUNC_READ_HOLDING && function_code != FUNC_READ_INPUT {
            return Err(format!(
                "ModbusRequest: function code must be 3 or 4, got {function_code}"
            ));
        }

        Ok(Self {
            slave_address,
            function_code,
            start_reg: u16::from_be_bytes([packet[2], packet[3]]),
            num_regs: u16::from_be_bytes([packet[4], packet[5]]),
        })
    }

    pub fn to_buffer(&self) -> Vec<u8> {
        let mut packet = vec![0u8; 8];
        packet[0] = self.slave_address;
        packet[1] = self.function_code;
        packet[2..4].copy_from_slice(&self.start_reg.to_be_bytes());
        packet[4..6].copy_from_slice(&self.num_regs.to_be_bytes());
        let crc = crc16(&packet[..6]);
        packet[6..8].copy_from_slice(&crc.to_le_bytes());
        packet
    }

    /// Returns `(register address, byte index into the response payload)` pairs,
    /// stepping two registers (4 bytes) at a time, mirroring the TS implementation.
    pub fn registers(&self) -> Vec<(u16, usize)> {
        let mut out = Vec::new();
        let end = self.start_reg as u32 + self.num_regs as u32;
        let mut register = self.start_reg as u32;
        let mut byte_index = 0usize;
        while register < end {
            out.push((register as u16, byte_index));
            register += 2;
            byte_index += 4;
        }
        out
    }
}

impl std::fmt::Display for ModbusRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "[{}] [{}] [{} -> {}]",
            self.slave_address,
            self.function_code,
            self.start_reg,
            self.start_reg as u32 + self.num_regs as u32 - 1
        )
    }
}

#[derive(Clone, Debug)]
pub struct ModbusResponse {
    pub request: ModbusRequest,
    pub regs: Vec<u8>,
}

impl ModbusResponse {
    pub fn from_packet(request: ModbusRequest, packet: &[u8]) -> Result<Self, String> {
        if packet.len() % 2 != 1 {
            return Err(format!("ModbusResponse: packet length must be odd: {}", hex(packet)));
        }
        if packet[0] != request.slave_address {
            return Err("ModbusResponse: slave address mismatch".into());
        }
        if packet[1] != request.function_code {
            return Err("ModbusResponse: function code mismatch".into());
        }
        let payload_length = packet[2] as usize;
        if payload_length != request.num_regs as usize * 2 {
            return Err(format!(
                "ModbusResponse: asked for {} registers, got {}",
                request.num_regs,
                payload_length / 2
            ));
        }
        let regs = packet[3..3 + payload_length].to_vec();
        Ok(Self { request, regs })
    }

    pub fn from_regs(request: ModbusRequest, regs: Vec<u8>) -> Self {
        Self { request, regs }
    }

    pub fn to_buffer(&self) -> Vec<u8> {
        let mut packet = vec![0u8; self.regs.len() + 5];
        packet[0] = self.request.slave_address;
        packet[1] = self.request.function_code;
        packet[2] = (self.request.num_regs * 2) as u8;
        packet[3..3 + self.regs.len()].copy_from_slice(&self.regs);
        let crc = crc16(&packet[..packet.len() - 2]);
        let len = packet.len();
        packet[len - 2..].copy_from_slice(&crc.to_le_bytes());
        packet
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum PacketKind {
    Request,
    Response,
}

/// What one [`ModbusParser::push_counted`] found: the frames, and how many
/// bytes were discarded as junk (line noise, or a frame whose CRC failed).
pub struct Pushed {
    pub packets: Vec<Vec<u8>>,
    pub dropped: usize,
}

/// Incremental CRC-framed Modbus RTU packet scanner.
pub struct ModbusParser {
    buffer: Vec<u8>,
    kind: PacketKind,
}

impl ModbusParser {
    pub fn new(kind: PacketKind) -> Self {
        Self {
            buffer: Vec::new(),
            kind,
        }
    }

    pub fn push(&mut self, chunk: &[u8]) -> Vec<Vec<u8>> {
        self.push_counted(chunk).packets
    }

    /// As [`Self::push`], but also reports how many bytes were thrown away.
    /// The transports surface that as a framing-error count: a bus that is
    /// silently dropping bytes still *works*, so without this the first symptom
    /// would be a rising timeout rate with nothing to explain it.
    pub fn push_counted(&mut self, chunk: &[u8]) -> Pushed {
        self.buffer.extend_from_slice(chunk);

        let mut packets = Vec::new();
        let len = self.buffer.len();
        let mut search_from = 0usize;
        let mut trunc_point = 0usize;

        // Find the earliest valid frame at or after `search_from`. Bytes before
        // a frame's start are junk and get dropped once the frame is accepted;
        // if nothing matches we keep the buffer for the next chunk.
        'scan: while search_from + MIN_PACKET_LENGTH <= len {
            let mut found: Option<(usize, usize)> = None;

            for start in search_from..=len - MIN_PACKET_LENGTH {
                let mut end = start + MIN_PACKET_LENGTH;
                while end <= len {
                    let expected = crc16(&self.buffer[start..end - 2]);
                    let actual =
                        u16::from_le_bytes([self.buffer[end - 2], self.buffer[end - 1]]);
                    if expected == actual && self.is_valid(&self.buffer[start..end]) {
                        found = Some((start, end));
                        break;
                    }
                    end += 1;
                }
                if found.is_some() {
                    break;
                }
            }

            match found {
                Some((start, end)) => {
                    if start > trunc_point {
                        tracing::debug!(
                            "clearing {} bytes of junk before frame",
                            start - trunc_point
                        );
                    }
                    packets.push(self.buffer[start..end].to_vec());
                    trunc_point = end;
                    search_from = end;
                }
                None => break 'scan,
            }
        }

        // Everything up to the last accepted frame leaves the buffer; what did
        // not become a frame is the junk count.
        let framed: usize = packets.iter().map(Vec::len).sum();
        let dropped = trunc_point.saturating_sub(framed);
        if trunc_point > 0 {
            self.buffer.drain(..trunc_point);
        }

        Pushed { packets, dropped }
    }

    fn is_valid(&self, packet: &[u8]) -> bool {
        match self.kind {
            PacketKind::Request => ModbusRequest::parse(packet).is_ok(),
            PacketKind::Response => {
                if packet.len() < 5 {
                    return false;
                }
                let function_code = packet[1];
                // A Modbus exception reply is five bytes: address, function
                // code with the high bit set, the exception code, CRC. It is a
                // real answer from a real device — and the only sign a register
                // was refused rather than the device being absent — so it must
                // not be discarded as junk.
                if function_code & 0x80 != 0 {
                    return matches!(
                        function_code & 0x7f,
                        FUNC_READ_HOLDING | FUNC_READ_INPUT
                    ) && packet.len() == 5;
                }
                if function_code != FUNC_READ_HOLDING && function_code != FUNC_READ_INPUT {
                    return false;
                }
                let payload_length = packet[2] as usize;
                payload_length == packet.len() - 5
            }
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_round_trip() {
        let req = ModbusRequest::new(1, 4, 12, 2);
        let buf = req.to_buffer();
        assert_eq!(buf.len(), 8);
        let parsed = ModbusRequest::parse(&buf).unwrap();
        assert_eq!(parsed, req);
    }

    #[test]
    fn parser_finds_request() {
        let req = ModbusRequest::new(2, 4, 33057, 2).to_buffer();
        let mut parser = ModbusParser::new(PacketKind::Request);
        let found = parser.push(&req);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0], req);
    }

    #[test]
    fn parser_skips_junk() {
        let req = ModbusRequest::new(1, 4, 0, 2).to_buffer();
        let mut junk = vec![0xde, 0xad, 0xbe, 0xef];
        junk.extend_from_slice(&req);
        let mut parser = ModbusParser::new(PacketKind::Request);
        let found = parser.push(&junk);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0], req);
    }

    #[test]
    fn response_round_trip() {
        let req = ModbusRequest::new(1, 4, 12, 2);
        let res = ModbusResponse::from_regs(req.clone(), vec![0x42, 0x48, 0x00, 0x00]);
        let buf = res.to_buffer();
        let parsed = ModbusResponse::from_packet(req, &buf).unwrap();
        assert_eq!(parsed.regs, vec![0x42, 0x48, 0x00, 0x00]);
    }
}
