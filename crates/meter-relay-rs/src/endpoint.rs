use std::fmt;
use std::time::Duration;

use anyhow::{anyhow, bail, Context};
use tokio::net::TcpStream;
use tokio::time::timeout;

use crate::stream::BoxStream;

/// Line speed for every serial endpoint unless the spec says otherwise. The
/// grid meter and the inverter-pi's ser2net both run 9600 8N1.
pub const DEFAULT_BAUD: u32 = 9600;

/// One place a Modbus conversation can happen.
///
/// Either a local serial port (the USB grid-meter reader on this host) or a
/// TCP endpoint (the inverter-pi bridges each of its USB adapters onto a TCP
/// port with ser2net). Endpoints are values rather than fixed configuration
/// because those remote adapters re-enumerate: which *role* a port plays — the
/// meter emulator for one inverter, or the shared stats bus — is discovered at
/// startup and must not be assumed from the port number.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Endpoint {
    Serial { path: String, baud: u32 },
    Tcp { host: String, port: u16 },
}

impl Endpoint {
    pub fn serial(path: impl Into<String>, baud: u32) -> Self {
        Self::Serial {
            path: path.into(),
            baud,
        }
    }

    pub fn tcp(host: impl Into<String>, port: u16) -> Self {
        Self::Tcp {
            host: host.into(),
            port,
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Self::Serial { .. } => "serial",
            Self::Tcp { .. } => "tcp",
        }
    }

    /// The grid meter is a local USB device. Discovery uses this to decide the
    /// order it asks questions in, and to refuse to call a network endpoint a
    /// meter (an inverter answers the meter's own registers too — they overlap
    /// its map — so a network endpoint must never be classified that way).
    pub fn is_serial(&self) -> bool {
        matches!(self, Self::Serial { .. })
    }

    /// Opens the endpoint. Every connection in the service goes through here,
    /// so the connect timeout is applied in exactly one place.
    pub async fn connect(&self, connect_timeout: Duration) -> anyhow::Result<BoxStream> {
        match self {
            Self::Serial { path, baud } => {
                // `SerialStream::open` is a blocking call in tokio-serial, and
                // it is a local device open: it either succeeds at once or the
                // path does not exist. Only the network path needs a timeout.
                let builder = tokio_serial::new(path, *baud);
                let stream = tokio_serial::SerialStream::open(&builder)
                    .with_context(|| format!("opening serial device {path}"))?;
                Ok(Box::new(stream))
            }
            Self::Tcp { host, port } => {
                let stream = timeout(connect_timeout, TcpStream::connect((host.as_str(), *port)))
                    .await
                    .map_err(|_| anyhow!("connecting to {host}:{port} timed out"))?
                    .with_context(|| format!("connecting to {host}:{port}"))?;
                // Modbus RTU frames are small and request/response; Nagle only
                // ever adds latency.
                let _ = stream.set_nodelay(true);
                Ok(Box::new(stream))
            }
        }
    }
}

impl fmt::Display for Endpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Serial { path, baud } => write!(f, "serial:{path}@{baud}"),
            Self::Tcp { host, port } => write!(f, "tcp://{host}:{port}"),
        }
    }
}

/// Widest `host:from-to` range we will expand. A typo like `2000-2999` should
/// be an error, not two thousand connection attempts.
const MAX_PORT_RANGE: u16 = 32;

/// Parses a comma-separated endpoint list into concrete endpoints.
///
/// Accepted forms, so the same variable can name a device file or a bridge:
///
/// ```text
/// /dev/serial/by-id/usb-FTDI_USB_Serial_Converter_FTB6SPL3-if00-port0
/// serial:/dev/ttyUSB2
/// 192.168.49.30:2002
/// tcp://192.168.49.30:2002
/// 192.168.49.30:2000-2003      (expands to four endpoints)
/// ```
pub fn parse_specs(spec: &str, baud: u32) -> anyhow::Result<Vec<Endpoint>> {
    let mut out = Vec::new();
    for raw in spec.split(',') {
        let item = raw.trim();
        if item.is_empty() {
            continue;
        }
        out.extend(parse_one(item, baud)?);
    }
    Ok(out)
}

fn parse_one(item: &str, baud: u32) -> anyhow::Result<Vec<Endpoint>> {
    if let Some(rest) = item.strip_prefix("tcp://") {
        return parse_tcp(rest);
    }
    if let Some(rest) = item
        .strip_prefix("serial://")
        .or_else(|| item.strip_prefix("serial:"))
    {
        if rest.trim().is_empty() {
            bail!("serial endpoint {item:?} has no device path");
        }
        return Ok(vec![Endpoint::serial(rest.trim(), baud)]);
    }
    if item.starts_with('/') {
        return Ok(vec![Endpoint::serial(item, baud)]);
    }
    parse_tcp(item)
}

fn parse_tcp(rest: &str) -> anyhow::Result<Vec<Endpoint>> {
    let (host, port_spec) = rest.rsplit_once(':').ok_or_else(|| {
        anyhow!("endpoint {rest:?} is neither host:port nor an absolute device path")
    })?;
    if host.trim().is_empty() {
        bail!("endpoint {rest:?} has no host");
    }

    let ports: Vec<u16> = match port_spec.split_once('-') {
        Some((from, to)) => {
            let from: u16 = from
                .trim()
                .parse()
                .with_context(|| format!("endpoint {rest:?}: {from:?} is not a port"))?;
            let to: u16 = to
                .trim()
                .parse()
                .with_context(|| format!("endpoint {rest:?}: {to:?} is not a port"))?;
            if to < from {
                bail!("endpoint {rest:?}: port range runs backwards");
            }
            if to - from > MAX_PORT_RANGE {
                bail!(
                    "endpoint {rest:?}: port range spans {} ports, more than the {MAX_PORT_RANGE} \
                     allowed",
                    to - from + 1
                );
            }
            (from..=to).collect()
        }
        None => vec![port_spec
            .trim()
            .parse()
            .with_context(|| format!("endpoint {rest:?}: {port_spec:?} is not a port"))?],
    };

    Ok(ports
        .into_iter()
        .map(|port| Endpoint::tcp(host.trim(), port))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_device_path_and_a_tcp_endpoint() {
        let parsed = parse_specs("/dev/ttyUSB2, 192.168.49.30:2002", DEFAULT_BAUD).unwrap();
        assert_eq!(
            parsed,
            vec![
                Endpoint::serial("/dev/ttyUSB2", 9600),
                Endpoint::tcp("192.168.49.30", 2002),
            ]
        );
    }

    #[test]
    fn parses_the_prefixed_forms() {
        let parsed =
            parse_specs("serial:///dev/ttyUSB0,tcp://10.0.0.1:2000", DEFAULT_BAUD).unwrap();
        assert_eq!(
            parsed,
            vec![
                Endpoint::serial("/dev/ttyUSB0", 9600),
                Endpoint::tcp("10.0.0.1", 2000),
            ]
        );
    }

    #[test]
    fn expands_a_port_range() {
        let parsed = parse_specs("192.168.49.30:2000-2003", DEFAULT_BAUD).unwrap();
        let ports: Vec<u16> = parsed
            .iter()
            .map(|ep| match ep {
                Endpoint::Tcp { port, .. } => *port,
                other => panic!("expected tcp, got {other}"),
            })
            .collect();
        assert_eq!(ports, vec![2000, 2001, 2002, 2003]);
    }

    #[test]
    fn a_silly_range_is_rejected_rather_than_expanded() {
        let error = parse_specs("192.168.49.30:2000-2999", DEFAULT_BAUD).unwrap_err();
        assert!(error.to_string().contains("more than"), "{error}");
    }

    #[test]
    fn a_bare_host_is_not_an_endpoint() {
        assert!(parse_specs("192.168.49.30", DEFAULT_BAUD).is_err());
    }

    #[test]
    fn display_is_the_canonical_form() {
        assert_eq!(
            Endpoint::tcp("192.168.49.30", 2002).to_string(),
            "tcp://192.168.49.30:2002"
        );
        assert_eq!(
            Endpoint::serial("/dev/ttyUSB0", 9600).to_string(),
            "serial:/dev/ttyUSB0@9600"
        );
    }
}
