//! Startup auto-detection: which endpoint is which.
//!
//! The remote adapters live on a Raspberry Pi running ser2net, and they are
//! three (soon four) *identical* CH340 USB-serial adapters with no serial
//! numbers. Linux therefore names them `ttyUSB0`, `ttyUSB1`, … in probe order,
//! and the mapping from TCP port to physical line changes across reboots: the
//! port that was the Solis meter line yesterday can be the stats bus today.
//! Position is not identity, so this module asks the wires instead.
//!
//! Two techniques, deliberately in this order:
//!
//! 1. **Listen.** Open the endpoint read-only for a short window and see
//!    whether anything is talking. An inverter polling its grid meter is a
//!    Modbus *master*, so a meter-emulation line shows a stream of requests,
//!    and the set of registers the inverter asks for is a fingerprint of the
//!    make/model (`MR_<ID>_METER_POLL` overrides it for new hardware).
//! 2. **Probe.** Only on endpoints that stayed silent — never on a line known
//!    to be carrying an inverter's own traffic. The stats bus is silent until
//!    asked, so read each configured inverter's own power register at its slave
//!    address: whichever inverter answers identifies the bus. If no inverter
//!    answers, read the grid meter's voltage register; a plausible voltage
//!    identifies the physical meter.
//!
//! The configured ports are still read, but only as *hints*: to break a tie
//! between two inverters of the same model (whose fingerprints are identical),
//! or as an explicitly-unverified fallback when nothing is identifiable. Every
//! decision, and the evidence for it, ends up in [`DiscoveryReport`] and on the
//! diagnostics page.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::timeout;

use crate::config::Config;
use crate::diagnostics::{DiscoveryReport, Identification, Role};
use crate::endpoint::Endpoint;
use crate::meter;
use crate::parser::{ModbusParser, ModbusRequest, PacketKind};
use crate::stream::BoxStream;
use crate::util::now_ms;

/// A line must carry at least this many meter polls before its request patterns
/// are allowed to decide an identity. One stray frame is a coincidence.
const MIN_FRAMES_FOR_ID: u32 = 2;
/// How many frames must match a driver's own fingerprint before that driver can
/// claim the line.
const MIN_MATCHED_FRAMES: u32 = 2;
/// Minimum share of the *recognised* traffic (this driver's known polls versus
/// another driver's) a match has to account for. Two inverters of the same
/// model both score exactly 0.5 here and are separated by the margin rule
/// below, which is why the two thresholds are separate.
const MIN_FINGERPRINT_SCORE: f64 = 0.5;
/// How far clear of the runner-up a match must be. Two inverters of the same
/// model have identical fingerprints and cannot be told apart by listening.
const MIN_FINGERPRINT_MARGIN: f64 = 0.25;
/// Exchanges that count as proof a probe was answered.
const PROBE_ATTEMPTS: u32 = 2;
/// What a grid meter's voltage reading has to look like to believe it.
const METER_VOLTAGE_RANGE: std::ops::RangeInclusive<f32> = 50.0..=400.0;

/// Why a candidate endpoint is on the list. Never sufficient on its own: a hint
/// only breaks ties and provides a labelled fallback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Hint {
    GridMeter,
    Stats,
    Inverter(String),
}

/// One endpoint offered to the discovery phase.
#[derive(Clone, Debug)]
pub struct Candidate {
    pub endpoint: Endpoint,
    pub hint: Option<Hint>,
}

/// What the discovery phase decided one endpoint is.
#[derive(Clone, Debug)]
pub struct Assignment {
    pub role: Role,
    /// Inverter id for a meter-emulator line.
    pub identity: Option<String>,
    /// `None` when a required role could not be identified *and* its configured
    /// endpoint is already in use by something else — there is nowhere to
    /// connect, and guessing would be worse than not connecting.
    pub endpoint: Option<Endpoint>,
    /// False when the role is a required one that discovery could not confirm.
    pub identified: bool,
    pub identification: Identification,
    /// What the configuration claimed this endpoint was. Kept so the
    /// diagnostics page can show a stale hint beside the discovered truth.
    pub hint: Option<Hint>,
}

/// The bits of an inverter that discovery needs.
#[derive(Clone, Debug)]
pub struct Fingerprint {
    pub id: String,
    /// Slave address the inverter answers its own registers at on the stats bus.
    pub slave: u8,
    /// Register that proves this driver is present (its battery-power word).
    pub probe_regs: (u8, u16),
    /// Meter-poll requests this make/model is known to send.
    pub meter_poll: Vec<(u8, u16, u16)>,
    /// Where the configuration says this inverter's meter line is.
    pub hint_endpoint: Endpoint,
}

/// Everything discovery knows before it looks at a single wire.
#[derive(Clone, Debug)]
pub struct Plant {
    pub inverters: Vec<Fingerprint>,
    /// Where the configuration says the physical grid meter is.
    pub grid_meter_hint: Option<Endpoint>,
    /// Where the configuration says the shared stats bus is.
    pub stats_hint: Option<Endpoint>,
}

impl Plant {
    pub fn from_config(cfg: &Config) -> Self {
        Self {
            inverters: cfg
                .inverters
                .iter()
                .map(|inverter| Fingerprint {
                    id: inverter.id().to_string(),
                    slave: inverter.slave,
                    probe_regs: inverter.probe_regs,
                    meter_poll: inverter.meter_poll.clone(),
                    hint_endpoint: Endpoint::tcp(cfg.inverter_host.clone(), inverter.port),
                })
                .collect(),
            grid_meter_hint: cfg
                .serial_devices
                .first()
                .cloned()
                .or_else(|| Some(Endpoint::serial(cfg.serial_device.clone(), cfg.serial_baud))),
            stats_hint: Some(Endpoint::tcp(cfg.inverter_host.clone(), cfg.stats_port)),
        }
    }
}

/// The endpoint candidates, in the order they will be reported.
///
/// By default they are derived from the existing configuration — the stats
/// port, each inverter's port, and the USB meter path — so an existing
/// deployment gains discovery without changing a single line of its Nix. An
/// explicit `MR_ENDPOINTS` list (which may name a `host:2000-2003` range)
/// replaces the derived set; `MR_SERIAL_DEVICES` always adds local candidates.
pub fn candidates(cfg: &Config) -> Vec<Candidate> {
    let mut out: Vec<Candidate> = Vec::new();
    let mut push = |endpoint: Endpoint, hint: Option<Hint>| {
        if !out.iter().any(|candidate| candidate.endpoint == endpoint) {
            out.push(Candidate { endpoint, hint });
        }
    };

    if cfg.endpoints.is_empty() {
        push(
            Endpoint::tcp(cfg.inverter_host.clone(), cfg.stats_port),
            Some(Hint::Stats),
        );
        for inverter in &cfg.inverters {
            push(
                Endpoint::tcp(cfg.inverter_host.clone(), inverter.port),
                Some(Hint::Inverter(inverter.id().to_string())),
            );
        }
    } else {
        for endpoint in &cfg.endpoints {
            push(endpoint.clone(), hint_for(cfg, endpoint));
        }
    }

    for endpoint in &cfg.serial_devices {
        push(endpoint.clone(), hint_for(cfg, endpoint));
    }

    out
}

/// The configured intent for an endpoint, derived by matching it against the
/// ports and device paths the configuration already names. Applied to explicit
/// candidate lists too, so an explicit list does not lose its tie-breaks.
fn hint_for(cfg: &Config, endpoint: &Endpoint) -> Option<Hint> {
    match endpoint {
        Endpoint::Tcp { host, port } if host == &cfg.inverter_host => {
            if *port == cfg.stats_port {
                return Some(Hint::Stats);
            }
            cfg.inverters
                .iter()
                .find(|inverter| inverter.port == *port)
                .map(|inverter| Hint::Inverter(inverter.id().to_string()))
        }
        Endpoint::Serial { path, .. } if path == &cfg.serial_device => Some(Hint::GridMeter),
        _ => None,
    }
}

/// The meter-poll requests seen on one line while listening.
#[derive(Clone, Debug, Default)]
struct ListenProfile {
    /// `(function code, start register, register count)` → frames seen.
    patterns: BTreeMap<(u8, u16, u16), u32>,
    frames: u32,
    bytes: u64,
    /// Why listening ended early, if it did.
    error: Option<String>,
}

impl ListenProfile {
    fn record(&mut self, request: &ModbusRequest) {
        *self
            .patterns
            .entry((request.function_code, request.start_reg, request.num_regs))
            .or_default() += 1;
        self.frames += 1;
    }

    /// Frames seen that match one of `patterns`.
    fn matched_frames(&self, patterns: &[(u8, u16, u16)]) -> u32 {
        self.patterns
            .iter()
            .filter(|(pattern, _)| patterns.contains(pattern))
            .map(|(_, count)| *count)
            .sum()
    }

    /// How well a driver's fingerprint explains what was heard, against what
    /// the *other* drivers' fingerprints would explain.
    ///
    /// Deliberately not "what share of the traffic does this driver's signature
    /// cover". An inverter polls registers we have not catalogued — measured on
    /// the live plant, the Solax's traffic changes with its own state (a
    /// meter-scan loop of `fc3 reg 11` while it has no meter, `fc4 reg 12` and
    /// `fc4 reg 74` once it does) — and scoring by share meant a line whose
    /// only *observed* frames were an uncatalogued register scored below any
    /// usable threshold and could not be placed at all. What actually
    /// distinguishes one meter line from another is: does this line carry this
    /// driver's known polls, and none of another driver's?
    fn score(&self, expected: &[(u8, u16, u16)], foreign: &[(u8, u16, u16)]) -> f64 {
        if self.frames < MIN_FRAMES_FOR_ID {
            return 0.0;
        }
        let matched = self.matched_frames(expected);
        if matched < MIN_MATCHED_FRAMES {
            return 0.0;
        }
        let alien = self.matched_frames(foreign);
        matched as f64 / (matched + alien) as f64
    }

    /// A human-readable summary of what was on the wire, biggest pattern first.
    fn describe(&self) -> String {
        if self.frames == 0 {
            return match &self.error {
                Some(error) => format!("nothing heard ({error})"),
                None => "silent".to_string(),
            };
        }
        let mut patterns: Vec<(&(u8, u16, u16), &u32)> = self.patterns.iter().collect();
        patterns.sort_by(|a, b| b.1.cmp(a.1));
        let shown: Vec<String> = patterns
            .iter()
            .take(4)
            .map(|((fc, register, count), frames)| {
                format!("fc{fc} reg {register} n{count} ×{frames}")
            })
            .collect();
        let differing = patterns.len().saturating_sub(4);
        let more = if differing > 0 {
            format!(", +{differing} more")
        } else {
            String::new()
        };
        format!("{} meter polls: {}{more}", self.frames, shown.join(", "))
    }
}

#[derive(Clone, Debug, PartialEq)]
enum ProbeReply {
    Registers(Vec<u8>),
    Exception(u8),
}

#[derive(Clone, Debug)]
struct SlaveAnswer {
    inverter: String,
    slave: u8,
    reply: ProbeReply,
}

#[derive(Clone, Debug, Default)]
struct ProbeOutcome {
    /// Inverters that answered their own power register on this endpoint.
    answers: Vec<SlaveAnswer>,
    /// Voltage reported by the grid meter, when this endpoint turned out to be
    /// the physical meter.
    meter_voltage: Option<f32>,
    error: Option<String>,
}

impl ProbeOutcome {
    /// True when a device answered a register read (rather than refusing with a
    /// Modbus exception). Only a real answer identifies a stats bus: the meter
    /// replies to out-of-range reads with an exception, and an exception is
    /// evidence of *something* being there, not of an inverter.
    fn answered_with_registers(&self) -> bool {
        self.answers
            .iter()
            .any(|answer| matches!(answer.reply, ProbeReply::Registers(_)))
    }

    fn evidence(&self) -> String {
        let answers: Vec<String> = self
            .answers
            .iter()
            .map(|answer| match &answer.reply {
                ProbeReply::Registers(raw) if raw.len() >= 2 => format!(
                    "{} (slave {}, {} W)",
                    answer.inverter,
                    answer.slave,
                    u16::from_be_bytes([raw[0], raw[1]]) as i16
                ),
                ProbeReply::Registers(_) => format!("{} (slave {})", answer.inverter, answer.slave),
                ProbeReply::Exception(code) => {
                    format!(
                        "{} (slave {}, exception {code})",
                        answer.inverter, answer.slave
                    )
                }
            })
            .collect();
        format!("answered by {}", answers.join(", "))
    }
}

/// One endpoint's accumulated evidence, across discovery attempts.
#[derive(Clone, Debug)]
struct Gathered {
    endpoint: Endpoint,
    hint: Option<Hint>,
    profile: ListenProfile,
    probe: Option<ProbeOutcome>,
}

/// The result of the whole discovery phase.
pub struct DiscoveryOutcome {
    pub assignments: Vec<Assignment>,
    pub report: DiscoveryReport,
}

impl DiscoveryOutcome {
    pub fn grid_meter(&self) -> Option<&Assignment> {
        self.assignments
            .iter()
            .find(|assignment| assignment.role == Role::GridMeter)
    }

    pub fn stats(&self) -> Option<&Assignment> {
        self.assignments
            .iter()
            .find(|assignment| assignment.role == Role::StatsBus)
    }

    pub fn meter_line(&self, id: &str) -> Option<&Assignment> {
        self.assignments.iter().find(|assignment| {
            assignment.role == Role::MeterEmulator && assignment.identity.as_deref() == Some(id)
        })
    }

    /// Required roles that could not be confirmed, as human-readable labels.
    /// Strict mode refuses to start on these: running half-identified would
    /// mean answering one inverter's meter polls with another inverter's
    /// polarity, which is how you get positive feedback on a live plant.
    pub fn unidentified_required(&self) -> Vec<String> {
        self.assignments
            .iter()
            .filter(|assignment| !assignment.identified && assignment.role != Role::Unknown)
            .map(describe_role)
            .collect()
    }
}

fn describe_role(assignment: &Assignment) -> String {
    match (&assignment.role, &assignment.identity) {
        (Role::GridMeter, _) => "the grid meter".to_string(),
        (Role::StatsBus, _) => "the stats bus".to_string(),
        (Role::MeterEmulator, Some(id)) => format!("{id}'s meter line"),
        (Role::MeterEmulator, None) => "a meter line".to_string(),
        (Role::Unknown, _) => "an unassigned endpoint".to_string(),
    }
}

/// Runs the discovery phase: listen, probe, decide, retry while anything
/// required is still unplaced. Never panics and never returns an error — an
/// unusable deployment is reported through the assignments, and strict mode is
/// the caller's decision.
pub async fn discover(
    cfg: &Config,
    diagnostics: Option<&crate::diagnostics::Diagnostics>,
) -> DiscoveryOutcome {
    let plant = Plant::from_config(cfg);
    let candidates = candidates(cfg);
    let listen_window = Duration::from_millis(cfg.discovery.listen_ms);
    let probe_wait = Duration::from_millis(cfg.discovery.probe_ms);
    let connect_timeout = Duration::from_millis(cfg.discovery.connect_timeout_ms);
    let started = Instant::now();
    let mut log: Vec<String> = Vec::new();

    log.push(format!(
        "listening up to {} ms on {} endpoint(s): {}",
        cfg.discovery.listen_ms,
        candidates.len(),
        candidates
            .iter()
            .map(|candidate| candidate.endpoint.to_string())
            .collect::<Vec<_>>()
            .join(", ")
    ));

    let mut gathered: Vec<Gathered> = candidates
        .iter()
        .map(|candidate| Gathered {
            endpoint: candidate.endpoint.clone(),
            hint: candidate.hint.clone(),
            profile: ListenProfile::default(),
            probe: None,
        })
        .collect();

    let mut attempt = 0;
    while attempt < cfg.discovery.attempts {
        attempt += 1;

        // Listen on everything that has not spoken yet. Lines run in parallel,
        // so the phase costs one window, not one window per endpoint.
        let silent: Vec<usize> = gathered
            .iter()
            .enumerate()
            .filter(|(_, entry)| entry.profile.frames == 0)
            .map(|(index, _)| index)
            .collect();

        if !silent.is_empty() {
            let targets: Vec<(usize, Endpoint)> = silent
                .iter()
                .map(|&index| (index, gathered[index].endpoint.clone()))
                .collect();
            let profiles = futures::future::join_all(
                targets
                    .iter()
                    .map(|(_, endpoint)| listen(endpoint, listen_window, connect_timeout)),
            )
            .await;

            for ((index, _), profile) in targets.iter().zip(profiles) {
                let entry = &mut gathered[*index];
                if profile.frames > 0 {
                    entry.profile = profile;
                } else if entry.profile.error.is_none() {
                    entry.profile.error = profile.error;
                }
            }
        }

        // Probe only what stayed silent: sending a request onto a line that is
        // already carrying an inverter's own poll stream would interleave two
        // masters on one bus for no reason.
        let quiet: Vec<usize> = gathered
            .iter()
            .enumerate()
            .filter(|(_, entry)| entry.profile.frames == 0 && entry.probe.is_none())
            .map(|(index, _)| index)
            .collect();

        if !quiet.is_empty() {
            let targets: Vec<(usize, Endpoint)> = quiet
                .iter()
                .map(|&index| (index, gathered[index].endpoint.clone()))
                .collect();
            let probes = futures::future::join_all(
                targets
                    .iter()
                    .map(|(_, endpoint)| probe(endpoint, &plant, probe_wait, connect_timeout)),
            )
            .await;
            for ((index, _), outcome) in targets.iter().zip(probes) {
                gathered[*index].probe = Some(outcome);
            }
        }

        let decision = decide(&plant, &gathered);
        if decision.unidentified_required.is_empty() || attempt >= cfg.discovery.attempts {
            log.extend(decision.log);
            let identified = decision
                .assignments
                .iter()
                .filter(|assignment| assignment.identified && assignment.role != Role::Unknown)
                .count();
            let unidentified = decision
                .assignments
                .iter()
                .filter(|assignment| !assignment.identified)
                .count();
            if attempt > 1 {
                log.push(format!("settled after {attempt} attempts"));
            }

            let report = DiscoveryReport {
                mode: cfg.discovery.mode.as_str().to_string(),
                ran_at: now_ms(),
                duration_ms: started.elapsed().as_millis() as u64,
                listen_ms: cfg.discovery.listen_ms,
                attempts: attempt,
                candidates: candidates.len(),
                assigned: identified,
                unidentified,
                log,
            };
            if let Some(diagnostics) = diagnostics {
                diagnostics.set_discovery(report.clone());
            }
            return DiscoveryOutcome {
                assignments: decision.assignments,
                report,
            };
        }

        log.push(format!(
            "attempt {attempt}: still unidentified — {}; listening again",
            decision.unidentified_required.join(", ")
        ));
    }

    unreachable!("the attempt loop always returns on its last iteration")
}

/// Reads for `window` without ever writing, and reports what was heard.
async fn listen(endpoint: &Endpoint, window: Duration, connect_timeout: Duration) -> ListenProfile {
    let mut profile = ListenProfile::default();

    let mut stream = match endpoint.connect(connect_timeout).await {
        Ok(stream) => stream,
        Err(error) => {
            profile.error = Some(short(&error));
            return profile;
        }
    };

    let mut parser = ModbusParser::new(PacketKind::Request);
    let deadline = Instant::now() + window;
    let mut buf = [0u8; 1024];

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match timeout(remaining, stream.read(&mut buf)).await {
            Ok(Ok(0)) | Ok(Err(_)) => break,
            Ok(Ok(read)) => {
                profile.bytes += read as u64;
                for packet in parser.push(&buf[..read]) {
                    if let Ok(request) = ModbusRequest::parse(&packet) {
                        profile.record(&request);
                    }
                }
            }
            Err(_) => break,
        }
    }

    profile
}

/// Asks a silent endpoint who it is.
///
/// The order of the questions matters, and it is driven by what the devices
/// have in common. An inverter's own registers (`0x02`, `0x1c`) sit *inside*
/// the grid meter's register map, so a meter answers a question meant for an
/// inverter — measured on the live plant: probing the Solax's power register on
/// the USB meter line got a perfectly valid reply from the meter. The meter's
/// registers, on the other hand, are the only ones a meter answers with a
/// plausible mains voltage.
///
/// So a local serial candidate is asked the meter's voltage first, and only
/// falls through to the inverter probes if it does not answer; a network
/// endpoint is only ever asked about inverters, because it can never be the
/// local meter.
async fn probe(
    endpoint: &Endpoint,
    plant: &Plant,
    wait: Duration,
    connect_timeout: Duration,
) -> ProbeOutcome {
    let mut outcome = ProbeOutcome::default();

    let mut stream = match endpoint.connect(connect_timeout).await {
        Ok(stream) => stream,
        Err(error) => {
            outcome.error = Some(short(&error));
            return outcome;
        }
    };

    if endpoint.is_serial() {
        match meter_voltage(&mut stream, wait).await {
            Ok(voltage) => {
                outcome.meter_voltage = Some(voltage);
                return outcome;
            }
            Err(error) => outcome.error = Some(error),
        }
    }

    for inverter in &plant.inverters {
        let (function_code, address) = inverter.probe_regs;
        let request = ModbusRequest::new(inverter.slave, function_code, address, 1);
        if let Some(reply) = ask(&mut stream, &request, wait).await {
            outcome.answers.push(SlaveAnswer {
                inverter: inverter.id.clone(),
                slave: inverter.slave,
                reply,
            });
        }
    }

    outcome
}

/// One read of the meter's voltage register, accepted only when the answer
/// decodes as a float in a plausible mains range.
async fn meter_voltage(stream: &mut BoxStream, wait: Duration) -> Result<f32, String> {
    let request = ModbusRequest::new(1, 4, meter::R_VOLTAGE, 2);
    let Some(ProbeReply::Registers(raw)) = ask(stream, &request, wait).await else {
        return Err("no answer to the meter's voltage register".to_string());
    };
    if raw.len() < 4 {
        return Err("a short answer to the meter's voltage register".to_string());
    }
    let voltage = f32::from_bits(u32::from_be_bytes([raw[0], raw[1], raw[2], raw[3]]));
    if voltage.is_finite() && METER_VOLTAGE_RANGE.contains(&voltage) {
        Ok(voltage)
    } else {
        Err(format!("an implausible meter voltage ({voltage})"))
    }
}

/// Sends one request and waits for the answer to *that* request, ignoring
/// anything else on the wire.
async fn ask(
    stream: &mut BoxStream,
    request: &ModbusRequest,
    wait: Duration,
) -> Option<ProbeReply> {
    let mut parser = ModbusParser::new(PacketKind::Response);
    let mut buf = [0u8; 512];

    for _ in 0..PROBE_ATTEMPTS {
        if stream.write_all(&request.to_buffer()).await.is_err() {
            return None;
        }

        let deadline = Instant::now() + wait;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            match timeout(remaining, stream.read(&mut buf)).await {
                Ok(Ok(0)) | Ok(Err(_)) => return None,
                Ok(Ok(read)) => {
                    for packet in parser.push(&buf[..read]) {
                        if let Some(reply) = classify(request, &packet) {
                            return Some(reply);
                        }
                    }
                }
                Err(_) => break,
            }
        }
    }

    None
}

/// True when this frame is the answer to `request` — including a Modbus
/// exception reply, which proves a device is there even though it refused.
fn classify(request: &ModbusRequest, packet: &[u8]) -> Option<ProbeReply> {
    if packet.len() < 5 || packet[0] != request.slave_address {
        return None;
    }
    let function_code = packet[1];
    if function_code & 0x80 != 0 {
        if function_code & 0x7f == request.function_code && packet.len() == 5 {
            return Some(ProbeReply::Exception(packet[2]));
        }
        return None;
    }
    if function_code != request.function_code {
        return None;
    }
    let payload = packet[2] as usize;
    if packet.len() != payload + 5 || payload != request.num_regs as usize * 2 {
        return None;
    }
    Some(ProbeReply::Registers(packet[3..3 + payload].to_vec()))
}

struct Decision {
    assignments: Vec<Assignment>,
    unidentified_required: Vec<String>,
    log: Vec<String>,
}

/// A role the configuration requires, and where the configuration claims it
/// lives. Used to fill in whatever the wires did not settle.
struct Required {
    role: Role,
    identity: Option<String>,
    hint: Option<Endpoint>,
    what: &'static str,
    claimed: Hint,
}

/// Turns the evidence into a layout. Pure, so the interesting cases — a stale
/// hint, two identical inverters, a silent spare port — are unit-tested.
fn decide(plant: &Plant, gathered: &[Gathered]) -> Decision {
    let mut assignments: Vec<Assignment> = Vec::new();
    let mut log: Vec<String> = Vec::new();
    let mut claimed_inverters: Vec<String> = Vec::new();

    // Pass 1: lines that carried an inverter's meter polls.
    for entry in gathered {
        if entry.profile.frames == 0 {
            continue;
        }
        let evidence = entry.profile.describe();

        let mut scores: Vec<(&Fingerprint, f64)> = plant
            .inverters
            .iter()
            .filter(|fingerprint| !claimed_inverters.contains(&fingerprint.id))
            .map(|fingerprint| {
                // Everything the *other* inverters are known to send: a line
                // carrying another driver's known polls belongs to that driver.
                let foreign: Vec<(u8, u16, u16)> = plant
                    .inverters
                    .iter()
                    .filter(|other| other.id != fingerprint.id)
                    .flat_map(|other| other.meter_poll.clone())
                    .collect();
                (
                    fingerprint,
                    entry.profile.score(&fingerprint.meter_poll, &foreign),
                )
            })
            .collect();
        scores.sort_by(|a, b| b.1.total_cmp(&a.1));

        let best = scores.first().copied();
        let runner_up = scores.get(1).map(|(_, score)| *score).unwrap_or(0.0);
        let hint = match &entry.hint {
            Some(Hint::Inverter(id)) => Some(id.clone()),
            _ => None,
        };

        match best {
            Some((fingerprint, score)) if score >= MIN_FINGERPRINT_SCORE => {
                let clear = score - runner_up >= MIN_FINGERPRINT_MARGIN;
                let hinted = hint.as_deref() == Some(fingerprint.id.as_str());
                if clear || hinted {
                    let confidence = if clear { score } else { 0.6 };
                    let method = if clear {
                        Identification::listen_fingerprint(confidence, &evidence)
                    } else {
                        Identification::configured(format!(
                            "{evidence} — matches {0} and another inverter equally well, so the \
                             configured port decided it",
                            fingerprint.id
                        ))
                    };
                    log.push(format!(
                        "{}: {evidence} → {} (confidence {confidence:.2}{})",
                        entry.endpoint,
                        fingerprint.id,
                        if clear {
                            ""
                        } else {
                            ", tie broken by the configured port"
                        }
                    ));
                    claimed_inverters.push(fingerprint.id.clone());
                    assignments.push(Assignment {
                        role: Role::MeterEmulator,
                        identity: Some(fingerprint.id.clone()),
                        endpoint: Some(entry.endpoint.clone()),
                        identified: true,
                        identification: method,
                        hint: entry.hint.clone(),
                    });
                } else {
                    log.push(format!(
                        "{}: {evidence} — matches {} and at least one other inverter equally \
                         well; two identical inverters cannot be told apart by listening, so \
                         set their ports explicitly",
                        entry.endpoint, fingerprint.id
                    ));
                }
            }
            _ => {
                log.push(format!(
                    "{}: {evidence} — no configured inverter polls like this",
                    entry.endpoint
                ));
            }
        }
    }

    // Pass 2: endpoints that answered a probe.
    for entry in gathered {
        if entry.profile.frames > 0 {
            continue;
        }
        let Some(outcome) = &entry.probe else {
            continue;
        };

        if outcome.answered_with_registers() {
            let evidence = outcome.evidence();
            let already = assignments
                .iter()
                .any(|assignment| assignment.role == Role::StatsBus);
            if already {
                log.push(format!(
                    "{}: {evidence} — a second stats bus; ignoring it",
                    entry.endpoint
                ));
                continue;
            }
            log.push(format!(
                "{}: silent, then {evidence} → stats bus",
                entry.endpoint
            ));
            assignments.push(Assignment {
                role: Role::StatsBus,
                identity: None,
                endpoint: Some(entry.endpoint.clone()),
                identified: true,
                identification: Identification::probe(1.0, evidence),
                hint: entry.hint.clone(),
            });
            continue;
        }

        // The grid meter is a local serial device, and only a serial endpoint
        // can be classified as one: a network endpoint that answers the meter's
        // voltage register is an inverter whose own map overlaps it, not a
        // meter (see `probe`).
        if let Some(voltage) = outcome.meter_voltage.filter(|_| entry.endpoint.is_serial()) {
            let already = assignments
                .iter()
                .any(|assignment| assignment.role == Role::GridMeter);
            if already {
                log.push(format!(
                    "{}: answered {voltage:.1} V — a second meter; ignoring it",
                    entry.endpoint
                ));
                continue;
            }
            log.push(format!(
                "{}: answered {voltage:.1} V to the meter probe → grid meter",
                entry.endpoint
            ));
            assignments.push(Assignment {
                role: Role::GridMeter,
                identity: None,
                endpoint: Some(entry.endpoint.clone()),
                identified: true,
                identification: Identification::probe_meter(format!(
                    "grid meter voltage register read {voltage:.1} V"
                )),
                hint: entry.hint.clone(),
            });
            continue;
        }

        let reason = match &outcome.error {
            Some(error) => format!("could not be opened ({error})"),
            None => "silent, and nothing answered a probe".to_string(),
        };
        log.push(format!("{}: {reason}", entry.endpoint));
    }

    let used: Vec<Endpoint> = assignments
        .iter()
        .filter_map(|assignment| assignment.endpoint.clone())
        .collect();

    // Pass 3: fill in the roles the configuration requires. An unconfirmed role
    // still gets a row on the diagnostics page, and its configured endpoint is
    // used only when nothing else has claimed it.
    let mut required: Vec<Required> = Vec::new();
    required.push(Required {
        role: Role::GridMeter,
        identity: None,
        hint: plant.grid_meter_hint.clone(),
        what: "grid meter",
        claimed: Hint::GridMeter,
    });
    required.push(Required {
        role: Role::StatsBus,
        identity: None,
        hint: plant.stats_hint.clone(),
        what: "stats bus",
        claimed: Hint::Stats,
    });
    for fingerprint in &plant.inverters {
        required.push(Required {
            role: Role::MeterEmulator,
            identity: Some(fingerprint.id.clone()),
            hint: Some(fingerprint.hint_endpoint.clone()),
            what: "meter line",
            claimed: Hint::Inverter(fingerprint.id.clone()),
        });
    }

    for Required {
        role,
        identity,
        hint,
        what,
        claimed,
    } in required
    {
        let already = assignments.iter().any(|assignment| {
            assignment.role == role && assignment.identity.as_deref() == identity.as_deref()
        });
        if already {
            continue;
        }

        let endpoint = hint.filter(|endpoint| !used.contains(endpoint));
        let who = match &identity {
            Some(id) => format!("{id}'s {what}"),
            None => what.to_string(),
        };

        match endpoint {
            Some(endpoint) => {
                log.push(format!(
                    "{endpoint}: nothing identified it, so the configured {who} endpoint is used \
                     unverified"
                ));
                let identification = Identification::configured(format!(
                    "the configured endpoint for the {who}, used because discovery could not \
                     identify it"
                ));
                assignments.push(Assignment {
                    role,
                    identity,
                    endpoint: Some(endpoint),
                    identified: false,
                    identification,
                    hint: Some(claimed),
                });
            }
            None => {
                log.push(format!(
                    "the {who} could not be identified, and its configured endpoint is in use by \
                     something else — the configuration looks stale"
                ));
                assignments.push(Assignment {
                    role,
                    identity,
                    endpoint: None,
                    identified: false,
                    identification: Identification::none(),
                    hint: Some(claimed),
                });
            }
        }
    }

    // Pass 4: candidates nobody needed. Reported, never connected: an endpoint
    // with no configured role is a spare port, not a thing to poll.
    for entry in gathered {
        let known = assignments
            .iter()
            .any(|assignment| assignment.endpoint.as_ref() == Some(&entry.endpoint));
        if known {
            continue;
        }
        let reason = if entry.profile.frames > 0 {
            entry.profile.describe()
        } else {
            match &entry.probe {
                Some(outcome) => match &outcome.error {
                    Some(error) => format!("could not be opened ({error})"),
                    None => "nothing observed, and nothing answered a probe".to_string(),
                },
                None => "nothing observed".to_string(),
            }
        };
        log.push(format!("{}: unassigned ({reason})", entry.endpoint));
        assignments.push(Assignment {
            role: Role::Unknown,
            identity: None,
            endpoint: Some(entry.endpoint.clone()),
            identified: false,
            identification: Identification::none(),
            hint: entry.hint.clone(),
        });
    }

    let unidentified_required = assignments
        .iter()
        .filter(|assignment| !assignment.identified && assignment.role != Role::Unknown)
        .map(describe_role)
        .collect();

    Decision {
        assignments,
        unidentified_required,
        log,
    }
}

/// The layout the configuration names, taken at face value. This is what
/// `MR_DISCOVERY=off` runs, and it is the honest description of the old
/// behaviour: every role is where its port says it is, and nothing verified it.
pub fn configured_layout(cfg: &Config) -> DiscoveryOutcome {
    let plant = Plant::from_config(cfg);
    let mut decision = decide(&plant, &[]);
    let mut log = vec![
        "discovery is off (MR_DISCOVERY=off): the configured endpoints are used unverified"
            .to_string(),
    ];
    log.append(&mut decision.log);

    for assignment in &mut decision.assignments {
        assignment.identified = true;
        assignment.identification = Identification::configured(format!(
            "the configured endpoint for {} (discovery is off)",
            describe_role(assignment)
        ));
    }

    DiscoveryOutcome {
        report: DiscoveryReport {
            mode: cfg.discovery.mode.as_str().to_string(),
            ran_at: now_ms(),
            duration_ms: 0,
            listen_ms: 0,
            attempts: 0,
            candidates: decision.assignments.len(),
            assigned: decision.assignments.len(),
            unidentified: 0,
            log,
        },
        assignments: decision.assignments,
    }
}

fn short(error: &anyhow::Error) -> String {
    let text = error.to_string();
    text.lines().next().unwrap_or("unknown error").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fingerprint(
        id: &str,
        slave: u8,
        meter_poll: &[(u8, u16, u16)],
        hint_port: u16,
    ) -> Fingerprint {
        Fingerprint {
            id: id.to_string(),
            slave,
            probe_regs: (4, if slave == 2 { 33149 } else { 2 }),
            meter_poll: meter_poll.to_vec(),
            hint_endpoint: Endpoint::tcp("192.168.49.30", hint_port),
        }
    }

    /// The real plant: a Solis that bulk-reads the meter, a Solax that reads
    /// active power at two candidate addresses. Taken from captures of the live
    /// lines.
    fn plant() -> Plant {
        Plant {
            inverters: vec![
                fingerprint("solis", 2, &[(4, 342, 2), (4, 0, 76)], 2000),
                fingerprint("solax", 1, &[(4, 12, 2), (3, 11, 1), (4, 74, 2)], 2001),
            ],
            grid_meter_hint: Some(Endpoint::serial("/dev/meter", 9600)),
            stats_hint: Some(Endpoint::tcp("192.168.49.30", 2002)),
        }
    }

    fn heard(endpoint: Endpoint, hint: Option<Hint>, requests: &[(u8, u16, u16)]) -> Gathered {
        let mut profile = ListenProfile::default();
        for &(function_code, start_reg, num_regs) in requests {
            profile.record(&ModbusRequest::new(1, function_code, start_reg, num_regs));
        }
        Gathered {
            endpoint,
            hint,
            profile,
            probe: None,
        }
    }

    fn silent(endpoint: Endpoint, hint: Option<Hint>, probe: ProbeOutcome) -> Gathered {
        Gathered {
            endpoint,
            hint,
            profile: ListenProfile::default(),
            probe: Some(probe),
        }
    }

    /// The local USB meter, which answers the meter probe with a plausible
    /// mains voltage and nothing else.
    fn grid_meter_candidate() -> Gathered {
        silent(
            Endpoint::serial("/dev/meter", 9600),
            Some(Hint::GridMeter),
            ProbeOutcome {
                meter_voltage: Some(241.2),
                ..ProbeOutcome::default()
            },
        )
    }

    fn stats_probe(answers: &[(&str, u8)]) -> ProbeOutcome {
        ProbeOutcome {
            answers: answers
                .iter()
                .map(|(id, slave)| SlaveAnswer {
                    inverter: id.to_string(),
                    slave: *slave,
                    reply: ProbeReply::Registers(vec![0, 10]),
                })
                .collect(),
            ..ProbeOutcome::default()
        }
    }

    fn find<'a>(decision: &'a Decision, role: Role, identity: Option<&str>) -> &'a Assignment {
        decision
            .assignments
            .iter()
            .find(|assignment| {
                assignment.role == role && assignment.identity.as_deref() == identity
            })
            .unwrap_or_else(|| panic!("no {role:?} assignment for {identity:?}"))
    }

    // The live plant with the CH340 adapters shuffled: the Solis's meter polls
    // arrive on port 2001 and the Solax's on port 2000. Nothing in the observed
    // traffic says which port is which — only the fingerprints do.
    #[test]
    fn remembered_fingerprints_beat_the_configured_ports() {
        let gathered = vec![
            heard(
                Endpoint::tcp("192.168.49.30", 2001),
                Some(Hint::Inverter("solis".into())),
                &[(4, 342, 2), (4, 0, 76)],
            ),
            heard(
                Endpoint::tcp("192.168.49.30", 2000),
                Some(Hint::Inverter("solax".into())),
                &[(4, 12, 2), (3, 11, 1)],
            ),
            silent(
                Endpoint::tcp("192.168.49.30", 2002),
                Some(Hint::Stats),
                stats_probe(&[("solax", 1), ("solis", 2)]),
            ),
            grid_meter_candidate(),
        ];

        let decision = decide(&plant(), &gathered);
        assert!(
            decision.unidentified_required.is_empty(),
            "{:?}",
            decision.log
        );

        let solis = find(&decision, Role::MeterEmulator, Some("solis"));
        assert_eq!(
            solis.endpoint,
            Some(Endpoint::tcp("192.168.49.30", 2001)),
            "the Solis line was found on the port configured for the Solax"
        );
        assert_eq!(solis.identification.method, "listen_fingerprint");
        assert!(solis.identification.confidence >= 0.99);

        let solax = find(&decision, Role::MeterEmulator, Some("solax"));
        assert_eq!(solax.endpoint, Some(Endpoint::tcp("192.168.49.30", 2000)));

        let stats = find(&decision, Role::StatsBus, None);
        assert_eq!(stats.endpoint, Some(Endpoint::tcp("192.168.49.30", 2002)));
        assert!(stats.identification.evidence.contains("solax"));
    }

    #[test]
    fn the_usual_layout_is_confirmed_without_any_swap() {
        let gathered = vec![
            heard(
                Endpoint::tcp("192.168.49.30", 2000),
                Some(Hint::Inverter("solis".into())),
                &[(4, 0, 76), (4, 342, 2), (4, 0, 76)],
            ),
            heard(
                Endpoint::tcp("192.168.49.30", 2001),
                Some(Hint::Inverter("solax".into())),
                &[(4, 12, 2), (4, 12, 2), (3, 11, 1)],
            ),
            silent(
                Endpoint::tcp("192.168.49.30", 2002),
                Some(Hint::Stats),
                stats_probe(&[("solax", 1), ("solis", 2)]),
            ),
            grid_meter_candidate(),
        ];

        let decision = decide(&plant(), &gathered);
        assert_eq!(
            find(&decision, Role::MeterEmulator, Some("solis")).endpoint,
            Some(Endpoint::tcp("192.168.49.30", 2000))
        );
        assert_eq!(
            find(&decision, Role::MeterEmulator, Some("solax")).endpoint,
            Some(Endpoint::tcp("192.168.49.30", 2001))
        );
        assert!(decision.unidentified_required.is_empty());
    }

    #[test]
    fn a_meter_probe_voltage_identifies_the_grid_meter() {
        let gathered = vec![
            // A local adapter that is not the meter: it polls the meter map
            // exactly like a Solax, so it is identified as one.
            heard(
                Endpoint::serial("/dev/ttyUSB0", 9600),
                None,
                &[(4, 12, 2), (3, 11, 1)],
            ),
            grid_meter_candidate(),
            heard(
                Endpoint::tcp("192.168.49.30", 2000),
                Some(Hint::Inverter("solis".into())),
                &[(4, 0, 76), (4, 342, 2)],
            ),
            silent(
                Endpoint::tcp("192.168.49.30", 2002),
                Some(Hint::Stats),
                stats_probe(&[("solax", 1), ("solis", 2)]),
            ),
        ];

        let decision = decide(&plant(), &gathered);
        let meter = find(&decision, Role::GridMeter, None);
        assert_eq!(meter.endpoint, Some(Endpoint::serial("/dev/meter", 9600)));
        assert!(meter.identified);
        assert!(meter.identification.evidence.contains("241.2"));
        // The device on ttyUSB0 speaks the Solax fingerprint, so it is a Solax
        // meter line — on a local adapter rather than the configured port.
        assert_eq!(
            find(&decision, Role::MeterEmulator, Some("solax")).endpoint,
            Some(Endpoint::serial("/dev/ttyUSB0", 9600))
        );
        assert!(
            decision.unidentified_required.is_empty(),
            "{:?}",
            decision.log
        );
    }

    #[test]
    fn two_identical_inverters_need_their_ports_to_break_the_tie() {
        let mut plant = plant();
        plant
            .inverters
            .push(fingerprint("solax2", 3, &[(4, 12, 2), (3, 11, 1)], 2003));

        // Both lines speak the Solax fingerprint, and the hints say which is
        // which: the configured port is the only thing that can decide.
        let gathered = vec![
            heard(
                Endpoint::tcp("192.168.49.30", 2001),
                Some(Hint::Inverter("solax".into())),
                &[(4, 12, 2), (3, 11, 1)],
            ),
            heard(
                Endpoint::tcp("192.168.49.30", 2003),
                Some(Hint::Inverter("solax2".into())),
                &[(4, 12, 2), (3, 11, 1)],
            ),
        ];

        let decision = decide(&plant, &gathered);
        assert_eq!(
            find(&decision, Role::MeterEmulator, Some("solax")).endpoint,
            Some(Endpoint::tcp("192.168.49.30", 2001))
        );
        assert_eq!(
            find(&decision, Role::MeterEmulator, Some("solax2")).endpoint,
            Some(Endpoint::tcp("192.168.49.30", 2003))
        );
    }

    #[test]
    fn two_identical_inverters_with_no_hints_are_left_unidentified() {
        let mut plant = plant();
        plant
            .inverters
            .push(fingerprint("solax2", 3, &[(4, 12, 2), (3, 11, 1)], 2003));

        // Port 2003 is not in the plant's hints, so neither line can be told
        // from the other. Guessing would be worse than reporting.
        let gathered = vec![
            heard(
                Endpoint::tcp("192.168.49.30", 2003),
                None,
                &[(4, 12, 2), (3, 11, 1)],
            ),
            heard(
                Endpoint::tcp("192.168.49.30", 2004),
                None,
                &[(4, 12, 2), (3, 11, 1)],
            ),
        ];

        let decision = decide(&plant, &gathered);
        assert!(
            decision
                .unidentified_required
                .contains(&"solax's meter line".to_string()),
            "{:?}",
            decision.unidentified_required
        );
        assert!(
            decision
                .unidentified_required
                .contains(&"solax2's meter line".to_string()),
            "{:?}",
            decision.unidentified_required
        );
    }

    #[test]
    fn a_required_line_that_never_speaks_falls_back_to_its_configured_port() {
        let gathered = vec![silent(
            Endpoint::tcp("192.168.49.30", 2000),
            Some(Hint::Inverter("solis".into())),
            ProbeOutcome {
                error: Some("connection refused".into()),
                ..ProbeOutcome::default()
            },
        )];

        let decision = decide(&plant(), &gathered);
        let solis = find(&decision, Role::MeterEmulator, Some("solis"));
        assert_eq!(solis.endpoint, Some(Endpoint::tcp("192.168.49.30", 2000)));
        assert!(
            !solis.identified,
            "an unverified fallback is not identified"
        );
        assert_eq!(solis.identification.method, "configured");
        assert!(decision
            .unidentified_required
            .contains(&"solis's meter line".to_string()));
        // The stats bus and grid meter are still filled in from their hints.
        assert!(find(&decision, Role::StatsBus, None).endpoint.is_some());
        assert!(find(&decision, Role::GridMeter, None).endpoint.is_some());
    }

    #[test]
    fn a_spare_port_is_reported_but_not_connected() {
        let gathered = vec![silent(
            Endpoint::tcp("192.168.49.30", 2003),
            None,
            ProbeOutcome::default(),
        )];

        let decision = decide(&plant(), &gathered);
        let spare = find(&decision, Role::Unknown, None);
        assert_eq!(spare.endpoint, Some(Endpoint::tcp("192.168.49.30", 2003)));
        assert!(!spare.identified);
        assert!(decision.log.iter().any(|line| line.contains("unassigned")));
    }

    #[test]
    fn a_single_stray_frame_is_not_enough_to_claim_an_inverter() {
        let gathered = vec![heard(
            Endpoint::tcp("192.168.49.30", 2000),
            Some(Hint::Inverter("solis".into())),
            &[(4, 0, 76)],
        )];
        let decision = decide(&plant(), &gathered);
        assert!(!find(&decision, Role::MeterEmulator, Some("solis")).identified);
        assert!(!decision.unidentified_required.is_empty());
    }

    #[test]
    fn a_line_polling_registers_no_driver_knows_is_not_claimed() {
        let gathered = vec![heard(
            Endpoint::tcp("192.168.49.30", 2000),
            Some(Hint::Inverter("solis".into())),
            &[(4, 900, 4), (4, 902, 4)],
        )];
        let decision = decide(&plant(), &gathered);
        assert!(decision
            .log
            .iter()
            .any(|line| line.contains("no configured inverter")));
    }

    // Measured on the live plant: with the relay stopped the Solax loses its
    // meter and falls back to a scan loop, so a listen window can catch a mix
    // of registers, some of which no fingerprint lists. Judging a match by what
    // *share* of the traffic a signature covers made this case fail; what
    // matters is that the driver's own polls are present and no other driver's
    // are.
    #[test]
    fn uncatalogued_registers_do_not_disqualify_an_otherwise_clear_match() {
        let gathered = vec![heard(
            Endpoint::tcp("192.168.49.30", 2000),
            Some(Hint::Inverter("solax".into())),
            &[(4, 900, 2), (4, 3, 2), (4, 74, 2), (4, 12, 2)],
        )];
        let decision = decide(&plant(), &gathered);
        let solax = find(&decision, Role::MeterEmulator, Some("solax"));
        assert!(solax.identified, "{:?}", decision.log);
        assert_eq!(solax.endpoint, Some(Endpoint::tcp("192.168.49.30", 2000)));
        assert_eq!(
            solax.identification.confidence, 1.0,
            "the two uncatalogued registers are not another driver's traffic"
        );
    }

    #[test]
    fn scoring_counts_a_foreign_fingerprint_against_a_match() {
        let mut profile = ListenProfile::default();
        for _ in 0..6 {
            profile.record(&ModbusRequest::new(1, 4, 0, 76));
        }
        for _ in 0..2 {
            profile.record(&ModbusRequest::new(1, 4, 12, 2));
        }

        let solis = [(4, 0, 76), (4, 342, 2)];
        let solax = [(4, 12, 2), (3, 11, 1), (4, 74, 2)];

        // Six frames of the Solis's bulk read, two of the Solax's power read.
        assert!((profile.score(&solis, &solax) - 6.0 / 8.0).abs() < 1e-9);
        assert!((profile.score(&solax, &solis) - 2.0 / 8.0).abs() < 1e-9);
        // A driver needs at least two matching frames to be considered at all,
        // and an uncatalogued pattern is nobody's fingerprint.
        assert_eq!(profile.score(&[(4, 999, 1)], &[]), 0.0);
        let mut single = ListenProfile::default();
        single.record(&ModbusRequest::new(1, 4, 0, 76));
        assert_eq!(single.score(&[(4, 0, 76)], &[]), 0.0);
    }

    #[test]
    fn the_driver_whose_known_polls_dominate_claims_a_mixed_line() {
        let gathered = vec![heard(
            Endpoint::tcp("192.168.49.30", 2005),
            None,
            &[
                (4, 0, 76),
                (4, 0, 76),
                (4, 0, 76),
                (4, 0, 76),
                (4, 12, 2),
                (4, 12, 2),
            ],
        )];
        let decision = decide(&plant(), &gathered);
        assert_eq!(
            find(&decision, Role::MeterEmulator, Some("solis")).endpoint,
            Some(Endpoint::tcp("192.168.49.30", 2005))
        );
        assert!(
            !find(&decision, Role::MeterEmulator, Some("solax")).identified,
            "the minority pattern must not win the line"
        );
    }

    #[test]
    fn a_network_endpoint_is_never_the_grid_meter() {
        // Observed on the live plant: the physical meter answers a probe aimed
        // at an inverter's power register, because that register sits inside the
        // meter's own map. The mirror image — a network endpoint answering the
        // meter's register — must not be read as "this is the meter", or the
        // grid meter would end up pointing at the stats bus.
        let gathered = vec![
            silent(
                Endpoint::tcp("192.168.49.30", 2002),
                Some(Hint::Stats),
                ProbeOutcome {
                    meter_voltage: Some(239.8),
                    ..ProbeOutcome::default()
                },
            ),
            grid_meter_candidate(),
        ];

        let decision = decide(&plant(), &gathered);
        assert_eq!(
            find(&decision, Role::GridMeter, None).endpoint,
            Some(Endpoint::serial("/dev/meter", 9600)),
            "the local meter, not the network endpoint that answered"
        );
        assert!(find(&decision, Role::GridMeter, None).identified);
    }

    #[test]
    fn the_stats_bus_wins_over_the_meter_probe() {
        let gathered = vec![silent(
            Endpoint::tcp("192.168.49.30", 2002),
            Some(Hint::Stats),
            ProbeOutcome {
                answers: stats_probe(&[("solax", 1)]).answers,
                // An inverter answered register 0 too; that must not turn the
                // stats bus into a "grid meter".
                meter_voltage: Some(230.0),
                error: None,
            },
        )];
        let decision = decide(&plant(), &gathered);
        assert_eq!(
            find(&decision, Role::StatsBus, None).endpoint,
            Some(Endpoint::tcp("192.168.49.30", 2002))
        );
        assert_ne!(
            find(&decision, Role::GridMeter, None).endpoint,
            Some(Endpoint::tcp("192.168.49.30", 2002))
        );
    }
}
