//! Per-connection health, for the diagnostics page and for the log.
//!
//! Every connection the service opens — the USB grid meter, the shared stats
//! bus, each inverter's meter emulator — owns one [`ConnectionStats`]. The
//! transports tick counters as frames move; the web layer reads them back as
//! [`ConnectionReport`]s. Nothing here is on the control path: a lock is held
//! for a few instructions and never across an `await`.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use serde::Serialize;

use crate::endpoint::Endpoint;
use crate::util::now_ms;

/// Health is judged over a sliding window of recent exchanges rather than over
/// lifetime counts. A line that failed a hundred times last week and has been
/// clean for the last hour is healthy, and a lifetime average would hide that.
pub const DEFAULT_WINDOW_SECS: u64 = 60;
/// Bounded ring of recent outcomes used for the error rate.
const OUTCOME_WINDOW: usize = 1024;
/// How many individual errors the page shows verbatim.
const RECENT_ERRORS: usize = 6;
/// Above this share of failed exchanges in the window the connection is
/// reported unhealthy even while it is nominally up.
const UNHEALTHY_ERROR_RATE: f64 = 0.2;

/// What a connection is for. Discovered at startup, not configured by port
/// number — see `discovery.rs`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// The local USB reader on the physical grid meter (this service is the
    /// Modbus master).
    GridMeter,
    /// The shared bus the relay polls every inverter's own registers on (the
    /// relay is the Modbus master).
    StatsBus,
    /// A link on which an inverter polls the fake grid meter (the inverter is
    /// the Modbus master and the relay answers).
    MeterEmulator,
    /// A candidate endpoint that was not identified as anything.
    Unknown,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::GridMeter => "grid_meter",
            Self::StatsBus => "stats_bus",
            Self::MeterEmulator => "meter_emulator",
            Self::Unknown => "unknown",
        }
    }
}

/// Where a connection is in its lifecycle. `Down` and `Unidentified` are the
/// two states worth waking up for: the first is a line that was working and
/// dropped, the second one the discovery phase could not place at all.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionState {
    /// Declared, not started yet.
    Idle,
    /// Dialling, or waiting out a reconnect backoff.
    Connecting,
    /// Open and exchanging frames.
    Online,
    /// Was open, is not any more; the supervisor is retrying.
    Down,
    /// Discovery could not work out what this endpoint is.
    Unidentified,
}

impl ConnectionState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Connecting => "connecting",
            Self::Online => "online",
            Self::Down => "down",
            Self::Unidentified => "unidentified",
        }
    }
}

/// How a connection was identified, and how much the guess is worth.
#[derive(Clone, Debug, Serialize)]
pub struct Identification {
    /// `listen_fingerprint`, `probe_slave`, `probe_meter`, `configured`, `none`.
    pub method: String,
    /// 0.0–1.0.
    pub confidence: f64,
    /// One line of human-readable evidence, shown on the diagnostics page.
    pub evidence: String,
    /// True when what was discovered disagrees with the configured port hint —
    /// i.e. the auto-detection overrode a stale assignment.
    pub mismatch: bool,
}

impl Identification {
    pub fn none() -> Self {
        Self {
            method: "none".into(),
            confidence: 0.0,
            evidence: "not identified".into(),
            mismatch: false,
        }
    }

    /// The configured port was taken at face value (discovery disabled, or the
    /// endpoint was not identifiable and the hint was used as a fallback).
    pub fn configured(evidence: impl Into<String>) -> Self {
        Self {
            method: "configured".into(),
            confidence: 0.5,
            evidence: evidence.into(),
            mismatch: false,
        }
    }

    pub fn listen_fingerprint(confidence: f64, evidence: impl Into<String>) -> Self {
        Self {
            method: "listen_fingerprint".into(),
            confidence,
            evidence: evidence.into(),
            mismatch: false,
        }
    }

    pub fn probe(confidence: f64, evidence: impl Into<String>) -> Self {
        Self {
            method: "probe_slave".into(),
            confidence,
            evidence: evidence.into(),
            mismatch: false,
        }
    }

    pub fn probe_meter(evidence: impl Into<String>) -> Self {
        Self {
            method: "probe_meter".into(),
            confidence: 0.9,
            evidence: evidence.into(),
            mismatch: false,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct RecentError {
    pub at: u64,
    pub kind: String,
    pub detail: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct ConnectionReport {
    pub id: String,
    pub role: String,
    pub label: String,
    pub endpoint: String,
    pub kind: String,
    pub state: String,
    pub healthy: bool,
    /// What the connection was discovered to be, when that is meaningful (an
    /// inverter id for a meter emulator line).
    pub identity: Option<String>,
    /// What the configured port hinted it would be.
    pub expected_identity: Option<String>,
    pub identification: Identification,
    pub connected_since: Option<u64>,
    pub last_rx: Option<u64>,
    pub last_tx: Option<u64>,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rx_frames: u64,
    pub tx_frames: u64,
    /// Requests received from an inverter (meter-emulator role).
    pub requests_in: u64,
    /// Answers written back to an inverter (meter-emulator role).
    pub responses_out: u64,
    /// Requests this service sent (master roles).
    pub polls_out: u64,
    /// Answers received from a device (master roles).
    pub responses_in: u64,
    pub timeouts: u64,
    /// Framing failures: bytes that never formed a valid CRC-framed frame.
    pub crc_errors: u64,
    /// Modbus exception replies and replies that would not decode.
    pub exceptions: u64,
    /// Socket/read/write/connect failures.
    pub io_errors: u64,
    pub reconnects: u64,
    /// Share of exchanges in the window that failed (0.0–1.0).
    pub error_rate: f64,
    pub window_secs: u64,
    /// Exchanges counted in the window, so a 0 % rate over 3 samples can be
    /// told apart from 0 % over 3000.
    pub window_samples: u64,
    pub recent_errors: Vec<RecentError>,
}

struct Outcomes {
    entries: VecDeque<(u64, bool)>,
    failures: u64,
}

struct Inner {
    state: ConnectionState,
    identity: Option<String>,
    identification: Identification,
    connected_since: Option<u64>,
    last_rx: Option<u64>,
    last_tx: Option<u64>,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_frames: u64,
    tx_frames: u64,
    requests_in: u64,
    responses_out: u64,
    polls_out: u64,
    responses_in: u64,
    timeouts: u64,
    crc_errors: u64,
    exceptions: u64,
    io_errors: u64,
    reconnects: u64,
    ever_connected: bool,
    outcomes: Outcomes,
    recent_errors: VecDeque<RecentError>,
    window_secs: u64,
}

/// One connection's live counters. Cheap to clone-share; tick it from the
/// transport tasks and read it from the web handler.
pub struct ConnectionStats {
    id: String,
    role: Role,
    label: String,
    /// `None` for a required role discovery could not place *and* whose
    /// configured endpoint was already taken: there is nothing to connect to,
    /// and the row exists so the diagnostics page can say so.
    endpoint: Option<Endpoint>,
    order: u32,
    expected_identity: Option<String>,
    inner: Mutex<Inner>,
}

impl ConnectionStats {
    pub fn new(
        id: impl Into<String>,
        role: Role,
        endpoint: Option<Endpoint>,
        expected_identity: Option<String>,
        order: u32,
    ) -> Arc<Self> {
        let id = id.into();
        let label = match (&role, &expected_identity) {
            (Role::GridMeter, _) => "Grid meter".to_string(),
            (Role::StatsBus, _) => "Stats bus".to_string(),
            (Role::MeterEmulator, Some(who)) => format!("{who} meter emulator"),
            (Role::MeterEmulator, None) => "Meter emulator".to_string(),
            (Role::Unknown, _) => "Unassigned".to_string(),
        };
        let identification = expected_identity
            .as_deref()
            .map(|_| {
                Identification::configured(format!(
                    "configured as {} until discovery says otherwise",
                    endpoint
                        .as_ref()
                        .map(|endpoint| endpoint.to_string())
                        .unwrap_or_else(|| "an unknown endpoint".to_string())
                ))
            })
            .unwrap_or_else(Identification::none);

        Arc::new(Self {
            id,
            role,
            label,
            endpoint,
            order,
            expected_identity,
            inner: Mutex::new(Inner {
                state: ConnectionState::Idle,
                identity: None,
                identification,
                connected_since: None,
                last_rx: None,
                last_tx: None,
                rx_bytes: 0,
                tx_bytes: 0,
                rx_frames: 0,
                tx_frames: 0,
                requests_in: 0,
                responses_out: 0,
                polls_out: 0,
                responses_in: 0,
                timeouts: 0,
                crc_errors: 0,
                exceptions: 0,
                io_errors: 0,
                reconnects: 0,
                ever_connected: false,
                outcomes: Outcomes {
                    entries: VecDeque::new(),
                    failures: 0,
                },
                recent_errors: VecDeque::new(),
                window_secs: DEFAULT_WINDOW_SECS,
            }),
        })
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn endpoint(&self) -> Option<&Endpoint> {
        self.endpoint.as_ref()
    }

    /// Records what discovery concluded. `identity` is the inverter id for a
    /// meter-emulator line; `mismatch` is derived, not passed, so it can never
    /// disagree with the two ids it compares.
    pub fn identify(&self, identity: Option<String>, identification: Identification) {
        let mut inner = self.inner.lock().unwrap();
        let mismatch = match (&identity, &self.expected_identity) {
            (Some(found), Some(expected)) => found != expected,
            _ => false,
        };
        inner.identification = Identification {
            mismatch,
            ..identification
        };
        inner.identity = identity;
    }

    pub fn set_state(&self, state: ConnectionState) {
        self.inner.lock().unwrap().state = state;
    }

    /// The socket is open: start a new session. `reconnects` counts every
    /// session after the first, which is exactly the number of times the link
    /// had to be rebuilt.
    pub fn mark_connected(&self) {
        let mut inner = self.inner.lock().unwrap();
        if inner.ever_connected {
            inner.reconnects += 1;
        }
        inner.ever_connected = true;
        inner.connected_since = Some(now_ms());
        inner.state = ConnectionState::Online;
    }

    pub fn mark_disconnected(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.state = ConnectionState::Down;
        inner.connected_since = None;
    }

    pub fn observe_rx(&self, bytes: u64, frames: u64) {
        let mut inner = self.inner.lock().unwrap();
        inner.rx_bytes += bytes;
        inner.rx_frames += frames;
        if bytes > 0 || frames > 0 {
            inner.last_rx = Some(now_ms());
        }
    }

    pub fn observe_tx(&self, bytes: u64, frames: u64) {
        let mut inner = self.inner.lock().unwrap();
        inner.tx_bytes += bytes;
        inner.tx_frames += frames;
        if bytes > 0 || frames > 0 {
            inner.last_tx = Some(now_ms());
        }
    }

    pub fn count_requests_in(&self, n: u64) {
        self.inner.lock().unwrap().requests_in += n;
    }

    pub fn count_responses_out(&self, n: u64) {
        self.inner.lock().unwrap().responses_out += n;
    }

    pub fn count_polls_out(&self, n: u64) {
        self.inner.lock().unwrap().polls_out += n;
    }

    pub fn count_responses_in(&self, n: u64) {
        self.inner.lock().unwrap().responses_in += n;
    }

    pub fn record_success(&self) {
        self.push_outcome(true);
    }

    /// Records a failure of `kind` — `timeout`, `crc`, `exception`, `io` — and
    /// keeps the last few verbatim for the diagnostics page.
    pub fn record_error(&self, kind: &str, detail: impl Into<String>) {
        let detail = detail.into();
        {
            let mut inner = self.inner.lock().unwrap();
            match kind {
                "timeout" => inner.timeouts += 1,
                "crc" => inner.crc_errors += 1,
                "exception" | "protocol" => inner.exceptions += 1,
                _ => inner.io_errors += 1,
            }
            if inner.recent_errors.len() == RECENT_ERRORS {
                inner.recent_errors.pop_front();
            }
            inner.recent_errors.push_back(RecentError {
                at: now_ms(),
                kind: kind.to_string(),
                detail,
            });
        }
        self.push_outcome(false);
    }

    /// Framing noise: bytes that never formed a valid frame. Counted, but
    /// deliberately *not* treated as a failed exchange — the exchange around it
    /// may well have succeeded, and a single line-noise byte should not move
    /// the error rate.
    pub fn record_framing_error(&self, detail: impl Into<String>) {
        let mut inner = self.inner.lock().unwrap();
        inner.crc_errors += 1;
        if inner.recent_errors.len() == RECENT_ERRORS {
            inner.recent_errors.pop_front();
        }
        inner.recent_errors.push_back(RecentError {
            at: now_ms(),
            kind: "crc".to_string(),
            detail: detail.into(),
        });
    }

    fn push_outcome(&self, ok: bool) {
        let now = now_ms();
        let mut inner = self.inner.lock().unwrap();
        let window_ms = inner.window_secs * 1_000;
        while let Some(&(at, failed)) = inner.outcomes.entries.front() {
            if now.saturating_sub(at) > window_ms {
                inner.outcomes.entries.pop_front();
                if failed {
                    inner.outcomes.failures -= 1;
                }
            } else {
                break;
            }
        }
        if inner.outcomes.entries.len() == OUTCOME_WINDOW {
            if let Some((_, failed)) = inner.outcomes.entries.pop_front() {
                if failed {
                    inner.outcomes.failures -= 1;
                }
            }
        }
        inner.outcomes.entries.push_back((now, !ok));
        if !ok {
            inner.outcomes.failures += 1;
        }
    }

    pub fn report(&self) -> ConnectionReport {
        let inner = self.inner.lock().unwrap();
        let samples = inner.outcomes.entries.len() as u64;
        let error_rate = if samples == 0 {
            0.0
        } else {
            inner.outcomes.failures as f64 / samples as f64
        };
        let healthy = inner.state == ConnectionState::Online && error_rate <= UNHEALTHY_ERROR_RATE;

        ConnectionReport {
            id: self.id.clone(),
            role: self.role.as_str().to_string(),
            label: self.label.clone(),
            endpoint: self
                .endpoint
                .as_ref()
                .map(|endpoint| endpoint.to_string())
                .unwrap_or_else(|| "unassigned".to_string()),
            kind: self
                .endpoint
                .as_ref()
                .map(|endpoint| endpoint.kind())
                .unwrap_or("none")
                .to_string(),
            state: inner.state.as_str().to_string(),
            healthy,
            identity: inner.identity.clone(),
            expected_identity: self.expected_identity.clone(),
            identification: inner.identification.clone(),
            connected_since: inner.connected_since,
            last_rx: inner.last_rx,
            last_tx: inner.last_tx,
            rx_bytes: inner.rx_bytes,
            tx_bytes: inner.tx_bytes,
            rx_frames: inner.rx_frames,
            tx_frames: inner.tx_frames,
            requests_in: inner.requests_in,
            responses_out: inner.responses_out,
            polls_out: inner.polls_out,
            responses_in: inner.responses_in,
            timeouts: inner.timeouts,
            crc_errors: inner.crc_errors,
            exceptions: inner.exceptions,
            io_errors: inner.io_errors,
            reconnects: inner.reconnects,
            error_rate,
            window_secs: inner.window_secs,
            window_samples: samples,
            recent_errors: inner.recent_errors.iter().cloned().collect(),
        }
    }
}

impl std::fmt::Debug for ConnectionStats {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionStats")
            .field("id", &self.id)
            .field("endpoint", &self.endpoint.as_ref().map(|e| e.to_string()))
            .finish_non_exhaustive()
    }
}

/// What the startup discovery phase concluded, for the top of the diagnostics
/// page. It is written once and then only read.
#[derive(Clone, Debug, Serialize)]
pub struct DiscoveryReport {
    /// `auto` or `off`.
    pub mode: String,
    pub ran_at: u64,
    pub duration_ms: u64,
    pub listen_ms: u64,
    pub attempts: u32,
    pub candidates: usize,
    pub assigned: usize,
    pub unidentified: usize,
    /// The decisions, in the order they were reached.
    pub log: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ConnectionsResponse {
    pub ts: u64,
    pub discovery: Option<DiscoveryReport>,
    pub connections: Vec<ConnectionReport>,
}

/// The set of connections the service knows about, in display order.
pub struct Diagnostics {
    connections: Mutex<Vec<(u32, Arc<ConnectionStats>)>>,
    discovery: Mutex<Option<DiscoveryReport>>,
}

impl Diagnostics {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            connections: Mutex::new(Vec::new()),
            discovery: Mutex::new(None),
        })
    }

    pub fn register(&self, stats: Arc<ConnectionStats>) -> Arc<ConnectionStats> {
        let mut connections = self.connections.lock().unwrap();
        if !connections
            .iter()
            .any(|(_, other)| other.id() == stats.id())
        {
            connections.push((stats.order, Arc::clone(&stats)));
        }
        stats
    }

    pub fn set_discovery(&self, report: DiscoveryReport) {
        *self.discovery.lock().unwrap() = Some(report);
    }

    pub fn report(&self) -> ConnectionsResponse {
        let mut connections = self.connections.lock().unwrap().clone();
        connections.sort_by_key(|(order, _)| *order);
        ConnectionsResponse {
            ts: now_ms(),
            discovery: self.discovery.lock().unwrap().clone(),
            connections: connections
                .into_iter()
                .map(|(_, stats)| stats.report())
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stats() -> Arc<ConnectionStats> {
        ConnectionStats::new(
            "solis",
            Role::MeterEmulator,
            Some(Endpoint::tcp("192.168.49.30", 2000)),
            Some("solis".into()),
            0,
        )
    }

    #[test]
    fn a_fresh_connection_is_idle_and_never_seen() {
        let report = stats().report();
        assert_eq!(report.state, "idle");
        assert!(!report.healthy);
        assert_eq!(report.last_rx, None);
        assert_eq!(report.error_rate, 0.0);
        assert_eq!(report.label, "solis meter emulator");
    }

    #[test]
    fn the_error_rate_is_windowed_over_recent_exchanges() {
        let stats = stats();
        stats.mark_connected();
        for _ in 0..99 {
            stats.record_success();
        }
        stats.record_error("timeout", "no reply");
        let report = stats.report();
        assert_eq!(report.window_samples, 100);
        assert_eq!(report.timeouts, 1);
        assert!(report.error_rate < 0.02, "{}", report.error_rate);
        assert!(report.healthy, "one timeout in a hundred is not unhealthy");

        for _ in 0..50 {
            stats.record_error("timeout", "no reply");
        }
        let report = stats.report();
        assert!(report.error_rate > 0.3, "{}", report.error_rate);
        assert!(!report.healthy, "a third of exchanges failing is unhealthy");
    }

    #[test]
    fn an_identification_that_contradicts_the_hint_is_flagged() {
        let stats = ConnectionStats::new(
            "solax",
            Role::MeterEmulator,
            Some(Endpoint::tcp("192.168.49.30", 2001)),
            Some("solax".into()),
            0,
        );
        stats.identify(
            Some("solis".into()),
            Identification::listen_fingerprint(1.0, "bulk meter poll"),
        );
        let report = stats.report();
        assert_eq!(report.identity.as_deref(), Some("solis"));
        assert_eq!(report.expected_identity.as_deref(), Some("solax"));
        assert!(report.identification.mismatch);
        assert_eq!(report.identification.method, "listen_fingerprint");
    }

    #[test]
    fn a_matching_identification_is_not_a_mismatch() {
        let stats = stats();
        stats.identify(
            Some("solis".into()),
            Identification::listen_fingerprint(1.0, "bulk meter poll"),
        );
        assert!(!stats.report().identification.mismatch);
    }

    #[test]
    fn traffic_counters_are_directional() {
        let stats = stats();
        stats.mark_connected();
        stats.observe_rx(64, 4);
        stats.observe_tx(32, 4);
        stats.count_requests_in(4);
        stats.count_responses_out(4);
        let report = stats.report();
        assert_eq!((report.rx_bytes, report.rx_frames), (64, 4));
        assert_eq!((report.tx_bytes, report.tx_frames), (32, 4));
        assert_eq!((report.requests_in, report.responses_out), (4, 4));
        assert_eq!((report.polls_out, report.responses_in), (0, 0));
        assert!(report.last_rx.is_some() && report.last_tx.is_some());
    }

    #[test]
    fn reconnects_count_sessions_after_the_first() {
        let stats = stats();
        stats.mark_connected();
        assert_eq!(stats.report().reconnects, 0);
        stats.mark_disconnected();
        assert_eq!(stats.report().state, "down");
        stats.mark_connected();
        stats.mark_disconnected();
        stats.mark_connected();
        assert_eq!(stats.report().reconnects, 2);
    }

    #[test]
    fn the_registry_reports_connections_in_display_order() {
        let diagnostics = Diagnostics::new();
        let second = ConnectionStats::new(
            "stats",
            Role::StatsBus,
            Some(Endpoint::tcp("192.168.49.30", 2002)),
            None,
            1,
        );
        diagnostics.register(second);
        diagnostics.register(stats());
        diagnostics.register(stats()); // registering twice must not duplicate

        let report = diagnostics.report();
        let ids: Vec<&str> = report
            .connections
            .iter()
            .map(|connection| connection.id.as_str())
            .collect();
        assert_eq!(ids, vec!["solis", "stats"]);
        assert!(report.discovery.is_none());
    }
}
