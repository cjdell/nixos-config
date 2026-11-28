use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt, ReadHalf, WriteHalf};
use tokio::sync::{oneshot, Mutex, Notify};
use tokio::time::timeout;

use crate::diagnostics::{ConnectionState, ConnectionStats};
use crate::endpoint::Endpoint;
use crate::parser::{ModbusParser, ModbusRequest, ModbusResponse, PacketKind};
use crate::stream::BoxStream;
use crate::util::crc16;

/// First reconnect delay. It doubles up to [`MAX_BACKOFF`], so a device that is
/// switched off is not hammered and one that comes back is picked up within a
/// few seconds.
const INITIAL_BACKOFF: Duration = Duration::from_millis(250);
const MAX_BACKOFF: Duration = Duration::from_secs(10);

/// Sends Modbus requests to a slave device and correlates the responses.
///
/// This is the "master" side of the bus (the service polling a real device) and
/// it also *owns* the connection: a supervisor task dials the endpoint, spawns
/// a reader, and re-dials whenever the link drops. That matters because the
/// remote adapters sit behind ser2net, which drops idle sessions, and because
/// the inverters reboot — without a supervisor a dropped link leaves the
/// service silently running on a dead socket with stale readings, forever.
///
/// A background task reads and frames responses; `send_request` serialises
/// access so only one request is in flight at a time.
pub struct ModbusSlaveGroup {
    name: String,
    endpoint: Endpoint,
    stats: Arc<ConnectionStats>,
    timeout: Duration,
    connect_timeout: Duration,
    /// Only set for the grid meter lane: how long its device may fail to open
    /// before the process exits, because an endpoint chosen by startup
    /// discovery can only be re-chosen by startup discovery. See
    /// [`device_vanished`].
    vanish_after: Option<Duration>,
    request_lock: Mutex<()>,
    writer: Mutex<Option<WriteHalf<BoxStream>>>,
    pending: Arc<Mutex<Option<oneshot::Sender<Vec<u8>>>>>,
    /// Raised by a reader when its socket ends, so the supervisor can reconnect.
    disconnected: Arc<Notify>,
}

impl ModbusSlaveGroup {
    pub fn new(
        endpoint: Endpoint,
        name: impl Into<String>,
        timeout: Duration,
        stats: Arc<ConnectionStats>,
        connect_timeout: Duration,
        vanish_after: Option<Duration>,
    ) -> Arc<Self> {
        let group = Arc::new(Self {
            name: name.into(),
            endpoint,
            stats,
            timeout,
            connect_timeout,
            vanish_after,
            request_lock: Mutex::new(()),
            writer: Mutex::new(None),
            pending: Arc::new(Mutex::new(None)),
            disconnected: Arc::new(Notify::new()),
        });

        tokio::spawn(supervise(Arc::clone(&group)));

        group
    }

    pub async fn send_request(&self, req: ModbusRequest) -> Result<ModbusResponse, String> {
        let _guard = self.request_lock.lock().await;

        let mut last_error = String::from("unknown");

        for _ in 0..2 {
            match self.exchange(&req.to_buffer()).await {
                Ok(packet) => {
                    if let Some(code) = exception_code(&packet) {
                        // A refused register is a real answer: retrying is still
                        // right (the device may be busy) but it is worth seeing.
                        self.stats.record_error(
                            "exception",
                            format!("device refused {req} with exception {code}"),
                        );
                        last_error = format!("exception {code}");
                    } else {
                        match ModbusResponse::from_packet(req.clone(), &packet) {
                            Ok(response) => {
                                self.stats.count_responses_in(1);
                                self.stats.record_success();
                                return Ok(response);
                            }
                            Err(err) => {
                                self.stats.record_error("protocol", err.clone());
                                last_error = err;
                            }
                        }
                    }
                }
                Err(err) => last_error = err,
            }
        }

        Err(format!("sendRequest: \"{}\" | {last_error}", self.name))
    }

    /// One write-and-await on the wire, shared by reads and writes.
    async fn exchange(&self, buffer: &[u8]) -> Result<Vec<u8>, String> {
        let (tx, rx) = oneshot::channel();

        let written = {
            let mut writer = self.writer.lock().await;
            match writer.as_mut() {
                Some(writer) => {
                    *self.pending.lock().await = Some(tx);
                    writer.write_all(buffer).await
                }
                // The supervisor owns reconnecting; report the state and let the
                // caller's own poll interval try again. Recording an error here
                // would flood the window while a device is simply unplugged.
                None => return Err(format!("sendRequest: \"{}\" | not connected", self.name)),
            }
        };

        if let Err(err) = written {
            *self.pending.lock().await = None;
            self.stats.record_error("io", format!("write failed: {err}"));
            return Err(err.to_string());
        }

        self.stats.observe_tx(buffer.len() as u64, 1);
        self.stats.count_polls_out(1);

        let packet = match timeout(self.timeout, rx).await {
            Ok(Ok(packet)) => packet,
            Ok(Err(_)) => {
                *self.pending.lock().await = None;
                self.stats
                    .record_error("io", "response channel closed mid-request");
                return Err("response channel closed".into());
            }
            Err(_) => {
                *self.pending.lock().await = None;
                self.stats
                    .record_error("timeout", format!("no reply within {:?}", self.timeout));
                return Err("timeout".into());
            }
        };

        *self.pending.lock().await = None;
        Ok(packet)
    }

    /// A single FC6 write on this lane, serialised against the poll loop by the
    /// same lock. An FC6 reply echoes the request (8 bytes) and therefore does
    /// not fit the read-shaped `ModbusResponse`, so the echo is checked here.
    pub async fn write_register(
        &self,
        slave: u8,
        address: u16,
        value: u16,
    ) -> Result<u16, String> {
        let _guard = self.request_lock.lock().await;

        let mut frame = vec![0u8; 8];
        frame[0] = slave;
        frame[1] = 6;
        frame[2..4].copy_from_slice(&address.to_be_bytes());
        frame[4..6].copy_from_slice(&value.to_be_bytes());
        let crc = crc16(&frame[..6]);
        frame[6..8].copy_from_slice(&crc.to_le_bytes());

        let mut last_error = String::from("unknown");
        for _ in 0..2 {
            match self.exchange(&frame).await {
                Ok(packet) => {
                    if let Some(code) = exception_code(&packet) {
                        self.stats.record_error(
                            "exception",
                            format!("device refused write {address}={value} with exception {code}"),
                        );
                        last_error = format!("exception {code}");
                    } else if packet.len() == 8
                        && packet[0] == slave
                        && packet[1] == 6
                        && packet[2..4] == address.to_be_bytes()
                        && packet[4..6] == value.to_be_bytes()
                    {
                        self.stats.count_responses_in(1);
                        self.stats.record_success();
                        return Ok(value);
                    } else {
                        self.stats
                            .record_error("protocol", "unexpected FC6 echo".to_string());
                        last_error = format!("unexpected echo ({} bytes)", packet.len());
                    }
                }
                Err(err) => last_error = err,
            }
        }

        Err(format!("writeRegister: \"{}\" | {last_error}", self.name))
    }
}

/// A Modbus exception reply is five bytes: address, function code with the high
/// bit set, exception code, CRC.
fn exception_code(packet: &[u8]) -> Option<u8> {
    if packet.len() == 5 && packet[1] & 0x80 != 0 {
        Some(packet[2])
    } else {
        None
    }
}

async fn supervise(group: Arc<ModbusSlaveGroup>) {
    let mut backoff = INITIAL_BACKOFF;
    let mut down_since: Option<Instant> = None;

    loop {
        group.stats.set_state(ConnectionState::Connecting);
        match group.endpoint.connect(group.connect_timeout).await {
            Ok(stream) => {
                down_since = None;
                let (read, write) = tokio::io::split(stream);
                *group.writer.lock().await = Some(write);
                group.stats.mark_connected();
                tracing::info!(name = %group.name, endpoint = %group.endpoint, "connection established");

                tokio::spawn(read_loop(
                    read,
                    Arc::clone(&group.pending),
                    group.name.clone(),
                    Arc::clone(&group.stats),
                    Arc::clone(&group.disconnected),
                ));

                // A notification raised before this await is still delivered,
                // so a reader that dies immediately cannot be missed.
                group.disconnected.notified().await;

                *group.writer.lock().await = None;
                *group.pending.lock().await = None;
                group.stats.mark_disconnected();
                backoff = INITIAL_BACKOFF;
                tracing::warn!(
                    name = %group.name,
                    endpoint = %group.endpoint,
                    "connection lost; reconnecting"
                );
                tokio::time::sleep(backoff).await;
            }
            Err(error) => {
                group
                    .stats
                    .record_error("io", format!("connect {}: {error}", group.endpoint));
                tracing::warn!(
                    name = %group.name,
                    endpoint = %group.endpoint,
                    error = %error,
                    "connect failed; retrying"
                );
                if let Some(patience) = group.vanish_after {
                    let down_for = down_since.get_or_insert_with(Instant::now).elapsed();
                    if device_vanished(&group.endpoint, down_for, patience) {
                        // Measured 2026-11-27: the meter's adapter died on the
                        // USB bus and this loop re-dialled its dead by-id name
                        // for nine hours while the plant ran on a frozen meter
                        // reading. A dead device node is not a link to wait
                        // out — only startup discovery can place the meter
                        // again, so exit and let systemd do exactly that.
                        tracing::error!(
                            name = %group.name,
                            endpoint = %group.endpoint,
                            down_for_ms = down_for.as_millis() as u64,
                            "the meter's serial device has vanished from the bus; exiting so the \
                             restart re-runs startup discovery, which probes every local port \
                             and places the meter wherever it now lives"
                        );
                        tokio::time::sleep(Duration::from_millis(200)).await; // let the log flush
                        std::process::exit(1);
                    }
                }
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(MAX_BACKOFF);
            }
        }
    }
}

/// Whether this endpoint's serial device node is *gone from the bus* — the
/// different failure from a device that is present but quiet. A device that
/// merely stopped answering may answer again on this connection; one that
/// has left the bus leaves the endpoint startup discovery chose invalid, and
/// this process cannot choose a new one.
fn device_vanished(endpoint: &Endpoint, down_for: Duration, patience: Duration) -> bool {
    down_for >= patience
        && matches!(endpoint, Endpoint::Serial { path, .. } if std::fs::metadata(path).is_err())
}

async fn read_loop(
    mut read: ReadHalf<BoxStream>,
    pending: Arc<Mutex<Option<oneshot::Sender<Vec<u8>>>>>,
    name: String,
    stats: Arc<ConnectionStats>,
    disconnected: Arc<Notify>,
) {
    let mut parser = ModbusParser::new(PacketKind::Response);
    let mut buf = [0u8; 1024];

    loop {
        match read.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                stats.observe_rx(n as u64, 0);
                let pushed = parser.push_counted(&buf[..n]);
                if pushed.dropped > 0 {
                    stats.record_framing_error(format!("{} junk byte(s) inbound", pushed.dropped));
                }
                for packet in pushed.packets {
                    stats.observe_rx(0, 1);
                    if let Some(tx) = pending.lock().await.take() {
                        let _ = tx.send(packet);
                    }
                }
            }
        }
    }

    tracing::warn!(name, "modbus read loop ended");
    disconnected.notify_one();
}

pub type RequestHandler =
    Arc<dyn Fn(ModbusRequest) -> Option<ModbusResponse> + Send + Sync + 'static>;

/// Accepts requests arriving over a stream (an inverter acting as Modbus
/// master) and answers them using `handler`, reconnecting if the line drops.
///
/// These are the meter-emulation lines: each inverter polls its grid meter on
/// its own port, and the relay has to keep answering — an inverter that stops
/// hearing its meter raises a metering fault (the Solis reports `Meter COM
/// Fail`) and stops following the relay's setpoint.
pub fn spawn_modbus_master(
    endpoint: Endpoint,
    name: impl Into<String>,
    handler: RequestHandler,
    stats: Arc<ConnectionStats>,
    connect_timeout: Duration,
) {
    let name = name.into();

    tokio::spawn(async move {
        let mut backoff = INITIAL_BACKOFF;

        loop {
            stats.set_state(ConnectionState::Connecting);
            match endpoint.connect(connect_timeout).await {
                Ok(stream) => {
                    stats.mark_connected();
                    tracing::info!(name = %name, endpoint = %endpoint, "inverter meter line established");

                    serve(stream, &name, Arc::clone(&handler), Arc::clone(&stats)).await;

                    stats.mark_disconnected();
                    backoff = INITIAL_BACKOFF;
                    tracing::warn!(
                        name = %name,
                        endpoint = %endpoint,
                        "inverter meter line lost; reconnecting"
                    );
                    tokio::time::sleep(backoff).await;
                }
                Err(error) => {
                    stats.record_error("io", format!("connect {endpoint}: {error}"));
                    tracing::warn!(
                        name = %name,
                        endpoint = %endpoint,
                        error = %error,
                        "inverter meter line could not be opened; retrying"
                    );
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(MAX_BACKOFF);
                }
            }
        }
    });
}

async fn serve(stream: BoxStream, name: &str, handler: RequestHandler, stats: Arc<ConnectionStats>) {
    let (mut read, mut write) = tokio::io::split(stream);
    let mut parser = ModbusParser::new(PacketKind::Request);
    let mut buf = [0u8; 1024];

    loop {
        match read.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                stats.observe_rx(n as u64, 0);
                let pushed = parser.push_counted(&buf[..n]);
                if pushed.dropped > 0 {
                    stats.record_framing_error(format!("{} junk byte(s) inbound", pushed.dropped));
                }
                for packet in pushed.packets {
                    let Ok(req) = ModbusRequest::parse(&packet) else {
                        continue;
                    };
                    stats.observe_rx(0, 1);
                    stats.count_requests_in(1);

                    let Some(response) = handler(req) else {
                        continue;
                    };
                    let buffer = response.to_buffer();
                    if let Err(err) = write.write_all(&buffer).await {
                        stats.record_error("io", format!("writing a meter response failed: {err}"));
                        return;
                    }
                    stats.observe_tx(buffer.len() as u64, 1);
                    stats.count_responses_out(1);
                    stats.record_success();
                }
            }
        }
    }

    tracing::warn!(name, "modbus master read loop ended");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnostics::Role;

    /// A fake device that answers every request it decodes with `value`, and
    /// optionally hangs up after the first answer so the client has to
    /// reconnect.
    async fn fake_device(value: u16, hang_up_after_first: bool) -> (u16, Arc<std::sync::atomic::AtomicUsize>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let accepts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let accepted = Arc::clone(&accepts);

        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    return;
                };
                let generation = accepted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                tokio::spawn(async move {
                    let mut parser = ModbusParser::new(PacketKind::Request);
                    let mut buf = [0u8; 256];
                    loop {
                        match socket.read(&mut buf).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => {
                                for packet in parser.push(&buf[..n]) {
                                    let Ok(request) = ModbusRequest::parse(&packet) else {
                                        continue;
                                    };
                                    let response =
                                        ModbusResponse::from_regs(request, value.to_be_bytes().to_vec());
                                    if socket.write_all(&response.to_buffer()).await.is_err() {
                                        return;
                                    }
                                    if hang_up_after_first && generation == 0 {
                                        // Drop the socket after the first answer.
                                        return;
                                    }
                                }
                            }
                        }
                    }
                });
            }
        });

        (port, accepts)
    }

    fn stats_for(port: u16) -> Arc<ConnectionStats> {
        ConnectionStats::new(
            "fake",
            Role::StatsBus,
            Some(Endpoint::tcp("127.0.0.1", port)),
            None,
            0,
        )
    }

    /// Retries until the supervisor has dialled and the device answers, so the
    /// tests do not depend on connect timing.
    async fn request_until_answered(group: &ModbusSlaveGroup) -> ModbusResponse {
        let request = ModbusRequest::new(1, 4, 0, 1);
        timeout(Duration::from_secs(5), async {
            loop {
                if let Ok(response) = group.send_request(request.clone()).await {
                    return response;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .expect("the fake device should have answered within 5 s")
    }

    #[tokio::test]
    async fn a_request_is_answered_and_counted() {
        let (port, _) = fake_device(42, false).await;
        let stats = stats_for(port);
        let group = ModbusSlaveGroup::new(
            Endpoint::tcp("127.0.0.1", port),
            "Fake",
            Duration::from_millis(400),
            Arc::clone(&stats),
            Duration::from_millis(500),
            None,
        );

        let response = request_until_answered(&group).await;
        assert_eq!(response.regs, vec![0x00, 0x2a]);

        let report = stats.report();
        assert_eq!(report.state, "online");
        assert_eq!(report.polls_out, 1);
        assert_eq!(report.responses_in, 1);
        assert_eq!(report.error_rate, 0.0);
        assert!(report.healthy, "{report:?}");
        assert!(report.last_rx.is_some() && report.last_tx.is_some());
    }

    #[tokio::test]
    async fn a_dropped_connection_is_rebuilt_without_a_restart() {
        let (port, accepts) = fake_device(7, true).await;
        let stats = stats_for(port);
        let group = ModbusSlaveGroup::new(
            Endpoint::tcp("127.0.0.1", port),
            "Fake",
            Duration::from_millis(300),
            Arc::clone(&stats),
            Duration::from_millis(500),
            None,
        );

        assert_eq!(request_until_answered(&group).await.regs, vec![0x00, 0x07]);

        // The device hung up after answering; the supervisor must dial again
        // and the next request must still succeed.
        assert_eq!(request_until_answered(&group).await.regs, vec![0x00, 0x07]);
        assert!(
            accepts.load(std::sync::atomic::Ordering::SeqCst) >= 2,
            "the supervisor should have re-dialled"
        );

        let report = stats.report();
        assert!(report.reconnects >= 1, "{report:?}");
        assert_eq!(report.state, "online");
    }

    #[test]
    fn a_serial_device_vanished_only_when_its_node_is_gone_and_time_is_up() {
        let dir = std::env::temp_dir().join(format!("meter-relay-vanish-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let node = dir.join("ttyTest");
        std::fs::write(&node, b"").unwrap();
        let endpoint = Endpoint::serial(node.display().to_string(), 9600);
        let patience = Duration::from_secs(60);

        // Present node: down as long as you like, it is not "gone".
        assert!(!device_vanished(
            &endpoint,
            Duration::from_secs(600),
            patience
        ));
        std::fs::remove_file(&node).unwrap();
        // Gone node, but the patience has not elapsed: keep dialling — this
        // is also the plug-and-replug window, which must not kill the plant.
        assert!(!device_vanished(&endpoint, Duration::from_secs(1), patience));
        assert!(device_vanished(&endpoint, Duration::from_secs(61), patience));
        // A network endpoint down forever is a link problem, never a vanished
        // device: discovery placed it, and it can be waited out.
        assert!(!device_vanished(
            &Endpoint::tcp("127.0.0.1", 1),
            Duration::from_secs(600),
            patience
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_meter_emulator_answers_incoming_requests() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        let stats = ConnectionStats::new(
            "solis",
            Role::MeterEmulator,
            Some(Endpoint::tcp("127.0.0.1", port)),
            Some("solis".into()),
            0,
        );
        let handler: RequestHandler = Arc::new(|request: ModbusRequest| {
            Some(ModbusResponse::from_regs(request, vec![0x12, 0x34]))
        });
        spawn_modbus_master(
            Endpoint::tcp("127.0.0.1", port),
            "Solis",
            handler,
            Arc::clone(&stats),
            Duration::from_millis(500),
        );

        // The emulator dials out; accept and drive it like an inverter.
        let (mut socket, _) = timeout(Duration::from_secs(5), listener.accept())
            .await
            .expect("the emulator should dial")
            .unwrap();
        let request = ModbusRequest::new(1, 4, 0, 1);
        socket.write_all(&request.to_buffer()).await.unwrap();

        let mut buf = [0u8; 64];
        let read = timeout(Duration::from_secs(5), socket.read(&mut buf))
            .await
            .expect("expected a reply")
            .unwrap();
        let response = ModbusResponse::from_packet(request, &buf[..read]).unwrap();
        assert_eq!(response.regs, vec![0x12, 0x34]);

        let report = stats.report();
        assert_eq!(report.requests_in, 1);
        assert_eq!(report.responses_out, 1);
        assert_eq!(report.rx_frames, 1);
        assert_eq!(report.tx_frames, 1);
    }
}
