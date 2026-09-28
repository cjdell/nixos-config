use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt, ReadHalf, WriteHalf};
use tokio::sync::{oneshot, Mutex};
use tokio::time::timeout;

use crate::parser::{ModbusParser, ModbusRequest, ModbusResponse, PacketKind};
use crate::stream::BoxStream;

/// Sends Modbus requests to a slave device and correlates the responses.
///
/// This is the "master" side of the bus (the service polling a real device).
/// A background task reads and frames responses; `send_request` serialises
/// access so only one request is in flight at a time.
pub struct ModbusSlaveGroup {
    name: String,
    timeout: Duration,
    request_lock: Mutex<()>,
    writer: Mutex<WriteHalf<BoxStream>>,
    pending: Arc<Mutex<Option<oneshot::Sender<Vec<u8>>>>>,
}

impl ModbusSlaveGroup {
    pub fn new(stream: BoxStream, name: impl Into<String>, timeout: Duration) -> Arc<Self> {
        let name = name.into();
        let (read, write) = tokio::io::split(stream);
        let pending: Arc<Mutex<Option<oneshot::Sender<Vec<u8>>>>> = Arc::new(Mutex::new(None));

        let group = Arc::new(Self {
            name: name.clone(),
            timeout,
            request_lock: Mutex::new(()),
            writer: Mutex::new(write),
            pending: Arc::clone(&pending),
        });

        tokio::spawn(read_loop(read, pending, name));

        group
    }

    pub async fn send_request(&self, req: ModbusRequest) -> Result<ModbusResponse, String> {
        let _guard = self.request_lock.lock().await;

        let mut last_error = String::from("unknown");

        for _ in 0..2 {
            let (tx, rx) = oneshot::channel();
            *self.pending.lock().await = Some(tx);

            {
                let mut writer = self.writer.lock().await;
                if let Err(err) = writer.write_all(&req.to_buffer()).await {
                    last_error = err.to_string();
                    *self.pending.lock().await = None;
                    continue;
                }
            }

            match timeout(self.timeout, rx).await {
                Ok(Ok(packet)) => {
                    return ModbusResponse::from_packet(req.clone(), &packet);
                }
                Ok(Err(_)) => last_error = "response channel closed".into(),
                Err(_) => last_error = "timeout".into(),
            }

            *self.pending.lock().await = None;
        }

        Err(format!(
            "sendRequest: \"{}\" | {last_error}",
            self.name
        ))
    }
}

async fn read_loop(
    mut read: ReadHalf<BoxStream>,
    pending: Arc<Mutex<Option<oneshot::Sender<Vec<u8>>>>>,
    name: String,
) {
    let mut parser = ModbusParser::new(PacketKind::Response);
    let mut buf = [0u8; 1024];

    loop {
        match read.read(&mut buf).await {
            Ok(0) | Err(_) => {
                tracing::warn!(name, "modbus slave read loop ended");
                break;
            }
            Ok(n) => {
                for packet in parser.push(&buf[..n]) {
                    if let Some(tx) = pending.lock().await.take() {
                        let _ = tx.send(packet);
                    }
                }
            }
        }
    }
}

pub type RequestHandler =
    Arc<dyn Fn(ModbusRequest) -> Option<ModbusResponse> + Send + Sync + 'static>;

/// Accepts requests arriving over a stream (an inverter acting as Modbus
/// master) and answers them using `handler`.
pub fn spawn_modbus_master(
    stream: BoxStream,
    name: impl Into<String>,
    handler: RequestHandler,
) {
    let name = name.into();
    tokio::spawn(async move {
        let (mut read, mut write) = tokio::io::split(stream);
        let mut parser = ModbusParser::new(PacketKind::Request);
        let mut buf = [0u8; 1024];

        loop {
            match read.read(&mut buf).await {
                Ok(0) | Err(_) => {
                    tracing::warn!(name, "modbus master read loop ended");
                    break;
                }
                Ok(n) => {
                    for packet in parser.push(&buf[..n]) {
                        let Ok(req) = ModbusRequest::parse(&packet) else {
                            continue;
                        };
                        if let Some(res) = handler(req) {
                            if write.write_all(&res.to_buffer()).await.is_err() {
                                tracing::warn!(name, "modbus master write failed");
                                return;
                            }
                        }
                    }
                }
            }
        }
    });
}
