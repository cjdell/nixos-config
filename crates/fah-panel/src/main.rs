//! fah-panel — folding@home heater telemetry web panel.
//!
//! The folding-box sibling of gpu-panel (which drives AMD GPUs through
//! sysfs overdrive). On these machines the GPU is an NVIDIA card with the
//! proprietary driver — no hwmon, no overdrive sysfs — so telemetry comes
//! from `nvidia-smi --query-gpu` polling and the single control the panel
//! exposes is the NVML power cap (`nvidia-smi -pl`), the one wattage knob
//! that works on a GeForce. The CPU columns reuse gpu-panel's cross-vendor
//! sysfs reads (coretemp/k10temp hwmon, per-core cpufreq, RAPL package
//! power), because the whole point of these boxes is that CPU and GPU are
//! fighting over the same small PSU.
//!
//! Zero dependencies: std only, frontend embedded via include_str!.
//!
//! ```text
//! browser ──HTTP/SSE──> fah-panel ──poll──> nvidia-smi (GPU util/power/temp/clocks)
//!                           │       └──> nvidia-smi -pl (power cap)
//!                           └────────> /sys: coretemp hwmon, cpufreq, RAPL
//! ```

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

// ---------------------------------------------------------------------------
// Small helpers (same kit as gpu-panel)
// ---------------------------------------------------------------------------

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn log(msg: &str) {
    println!("{} {msg}", now_ms());
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// f64 -> JSON, rounding noise away; NaN/inf become null.
fn fnum(v: f64) -> String {
    if !v.is_finite() {
        "null".into()
    } else {
        format!("{:.2}", (v * 100.0).round() / 100.0)
    }
}

/// f64 where <=0 already means "unavailable" -> JSON null for the UI.
fn fnum_pos(v: f64) -> String {
    if v.is_finite() && v > 0.0 {
        fnum(v)
    } else {
        "null".into()
    }
}

fn read_trim(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

fn read_u64(path: &str) -> Option<u64> {
    read_trim(path)?.parse().ok()
}

fn read_f64(path: &str) -> Option<f64> {
    read_trim(path)?.parse().ok()
}

/// Parse "82" / "116.16" / "N/A" CSV fields from nvidia-smi nounits output.
fn csv_f64(s: &str) -> f64 {
    s.trim().parse::<f64>().unwrap_or(0.0)
}

// ---------------------------------------------------------------------------
// nvidia-smi
// ---------------------------------------------------------------------------

/// Run nvidia-smi with the given args, returning trimmed stdout. Failure is
/// an Err with stderr (or exit code) so the sampler can surface it.
fn nvidia_smi(bin: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(bin)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("spawn {bin}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "exit {}: {}",
            out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

const POLL_FIELDS: &str = "utilization.gpu,memory.used,memory.total,temperature.gpu,fan.speed,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,pstate,clocks_throttle_reasons.active,clocks.max.graphics,clocks.max.memory";
const POLL_QUERY: &str = "--format=csv,noheader,nounits";

/// clocks_throttle_reasons.active is a bitmask; the names are what a user
/// wants to see ("why is it slow right now").
fn throttle_names(bits: u64) -> Vec<&'static str> {
    const NAMED: [(u64, &str); 8] = [
        (0x1, "gpu-idle"),
        (0x2, "applications-clocks"),
        (0x4, "hw-slowdown"),
        (0x8, "sw-slowdown"),
        (0x10, "sw-thermal-slowdown"),
        (0x20, "hw-thermal-shutdown"),
        (0x40, "sync-boost"),
        (0x80, "sw-power-cap"),
    ];
    NAMED.iter().filter(|(b, _)| bits & b != 0).map(|(_, n)| *n).collect()
}

/// One GPU sample. nvidia-smi semantics: unavailable values come back as
/// 0/"N/A"; we keep 0 and let the UI print "–" for the few that matter
/// (fan on auto is reported as 0 -> null by fnum_pos).
#[derive(Clone, Default)]
struct Sample {
    ts: i64,
    util: f64,
    mem_used: f64,
    mem_total: f64,
    temp: f64,
    fan: f64,
    power: f64,
    power_limit: f64,
    clock_gpu: f64,
    clock_mem: f64,
    clock_gpu_max: f64,
    clock_mem_max: f64,
    pstate: String,
    throttle: Vec<&'static str>,
    /// CPU package (RAPL) + GPU board power (NVML) = what the +12 V rail is
    /// being asked to supply. There are no real rail sensors on this board
    /// (the HP Super-I/O hwmon exposes nothing but a dead pwm1; no BMC), so
    /// this estimate plus the boot-time behaviour is the brownout monitor.
    total: f64,
    cpu_temp: f64,
    cpu_power: f64,
    ok: bool,
    error: String,
}

impl Sample {
    fn to_json(&self) -> String {
        format!(
            "{{\"ts\":{},\"util\":{},\"mem_used\":{},\"mem_total\":{},\"temp\":{},\
             \"fan\":{},\"power\":{},\"power_limit\":{},\"clock_gpu\":{},\"clock_mem\":{},\
             \"clock_gpu_max\":{},\"clock_mem_max\":{},\
             \"pstate\":\"{}\",\"throttle\":[{}],\"cpu_temp\":{},\"cpu_power\":{},\"total\":{},\
             \"ok\":{},\"error\":\"{}\"}}",
            self.ts,
            fnum(self.util),
            fnum(self.mem_used),
            fnum(self.mem_total),
            fnum(self.temp),
            fnum_pos(self.fan),
            fnum(self.power),
            fnum(self.power_limit),
            fnum(self.clock_gpu),
            fnum(self.clock_mem),
            fnum_pos(self.clock_gpu_max),
            fnum_pos(self.clock_mem_max),
            json_escape(&self.pstate),
            self.throttle.iter().map(|t| format!("\"{t}\"")).collect::<Vec<_>>().join(","),
            fnum_pos(self.cpu_temp),
            fnum(self.cpu_power),
            fnum(self.total),
            self.ok,
            json_escape(&self.error),
        )
    }
}

fn take_sample(bin: &str) -> Sample {
    let mut s = Sample::default();
    match nvidia_smi(bin, &[&format!("--query-gpu={POLL_FIELDS}"), POLL_QUERY]) {
        Ok(out) => {
            // One line (first GPU wins); fields as above.
            let line = out.lines().next().unwrap_or("").to_string();
            let f: Vec<&str> = line.split(',').map(|c| c.trim()).collect();
            if f.len() < 13 {
                s.error = format!("unexpected nvidia-smi output: {line}");
                return s;
            }
            s.util = csv_f64(f[0]);
            s.mem_used = csv_f64(f[1]);
            s.mem_total = csv_f64(f[2]);
            s.temp = csv_f64(f[3]);
            s.fan = csv_f64(f[4]);
            s.power = csv_f64(f[5]);
            s.power_limit = csv_f64(f[6]);
            s.clock_gpu = csv_f64(f[7]);
            s.clock_mem = csv_f64(f[8]);
            s.pstate = f[9].to_string();
            s.throttle = throttle_names(
                u64::from_str_radix(f[10].trim().trim_start_matches("0x"), 16).unwrap_or(0),
            );
            s.clock_gpu_max = csv_f64(f[11]);
            s.clock_mem_max = csv_f64(f[12]);
            s.ok = true;
        }
        Err(e) => s.error = e,
    }
    s.ts = now_ms();
    s
}

/// SMBIOS-configured memory bus speed (e.g. "2400 MT/s"), read once at
/// startup — it never changes live. Needs root (the service runs as root);
/// dmidecode 3.x says "Configured Memory Speed", older builds say
/// "Configured Clock Speed". Empty string when unknown/no dmidecode given.
fn ram_speed(dmi: &str) -> String {
    if dmi.is_empty() {
        return String::new();
    }
    let collect = |args: &[&str], speeds: &mut Vec<String>| {
        let Ok(out) = Command::new(dmi)
            .args(args)
            .stdin(Stdio::null())
            .output()
        else {
            return;
        };
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let t = line.trim();
            let Some(v) = t
                .strip_prefix("Configured Memory Speed:")
                .or_else(|| t.strip_prefix("Configured Clock Speed:"))
            else {
                continue;
            };
            let v = v.trim().to_string();
            if v.is_empty() || v.starts_with("Unknown") {
                continue;
            }
            if !speeds.contains(&v) {
                speeds.push(v);
            }
        }
    };
    // Type 17 (memory devices) carries per-DIMM configured speed; type 12
    // (system memory) is the board-level answer but does not exist in the
    // SMBIOS 2.7 tables of boards like this one. Collect both, in order.
    let mut speeds: Vec<String> = Vec::new();
    collect(&["-t", "memory"], &mut speeds);
    if speeds.is_empty() {
        collect(&["-t", "12"], &mut speeds);
    }
    speeds.join(" / ")
}

// ---------------------------------------------------------------------------
// CPU telemetry — ported from gpu-panel (k10temp/coretemp, cpufreq, RAPL)
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Cpu {
    /// hwmon directory, kept for debugging/logging; the temp paths below are
    /// what sampling actually uses.
    #[allow(dead_code)]
    hwmon: String,
    temps: Vec<(String, String)>,
    cur_freq: Vec<String>,
    max_freq: String,
    energy: String,
    energy_max: u64,
}

fn detect_cpu() -> Cpu {
    let mut hwmon = String::new();
    if let Ok(rd) = std::fs::read_dir("/sys/class/hwmon") {
        for e in rd.flatten() {
            let dir = format!("/sys/class/hwmon/{}", e.file_name().to_string_lossy());
            if matches!(
                read_trim(&format!("{dir}/name")).as_deref(),
                Some("k10temp") | Some("coretemp")
            ) {
                hwmon = dir;
                break;
            }
        }
    }

    let mut temps = Vec::new();
    if !hwmon.is_empty() {
        if let Ok(rd) = std::fs::read_dir(&hwmon) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                if let Some(prefix) = name.strip_suffix("_label") {
                    if !prefix.starts_with("temp") {
                        continue;
                    }
                    let input = format!("{hwmon}/{prefix}_input");
                    if std::path::Path::new(&input).exists() {
                        if let Some(label) = read_trim(&format!("{hwmon}/{name}")) {
                            temps.push((label, input));
                        }
                    }
                }
            }
        }
        temps.sort();
    }

    let mut found: Vec<(usize, String)> = Vec::new();
    if let Ok(rd) = std::fs::read_dir("/sys/devices/system/cpu") {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let rest = match name.strip_prefix("cpu") {
                Some(r) if !r.is_empty() && r.bytes().all(|b| b.is_ascii_digit()) => r,
                _ => continue,
            };
            let f = format!("/sys/devices/system/cpu/{name}/cpufreq/scaling_cur_freq");
            if std::path::Path::new(&f).exists() {
                found.push((rest.parse().unwrap_or(usize::MAX), f));
            }
        }
    }
    found.sort_by_key(|(i, _)| *i);

    let mut energy = String::new();
    let mut energy_max = 0;
    if let Ok(rd) = std::fs::read_dir("/sys/class/powercap") {
        for e in rd.flatten() {
            let dir = format!("/sys/class/powercap/{}", e.file_name().to_string_lossy());
            if read_trim(&format!("{dir}/name")).as_deref() != Some("package-0") {
                continue;
            }
            let f = format!("{dir}/energy_uj");
            if std::path::Path::new(&f).exists() {
                energy = f;
                energy_max = read_u64(&format!("{dir}/max_energy_range_uj")).unwrap_or(0);
            }
            break;
        }
    }

    Cpu {
        hwmon,
        temps,
        cur_freq: found.into_iter().map(|(_, p)| p).collect(),
        max_freq: "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq".to_string(),
        energy,
        energy_max,
    }
}

fn cpu_temp_by(cpu: &Cpu, prefix: &str) -> f64 {
    let pre = prefix.to_ascii_lowercase();
    let mut best: Option<f64> = None;
    for (label, path) in &cpu.temps {
        if !label.to_ascii_lowercase().starts_with(&pre) {
            continue;
        }
        if let Some(v) = read_f64(path) {
            best = Some(best.map_or(v, |b| b.max(v)));
        }
    }
    best.map(|v| v / 1000.0).unwrap_or(0.0)
}

/// The package sensor: AMD Tctl/Tdie, Intel "Package id 0"; fall back to the
/// hottest "Core".
fn cpu_pkg_temp(cpu: &Cpu) -> f64 {
    for p in ["Tctl", "Tdie", "Package id 0", "Package"] {
        let t = cpu_temp_by(cpu, p);
        if t > 0.0 {
            return t;
        }
    }
    cpu_temp_by(cpu, "Core")
}

fn cpu_clocks(cpu: &Cpu) -> (f64, f64) {
    let (mut sum, mut n, mut hi) = (0.0f64, 0usize, 0.0f64);
    for p in &cpu.cur_freq {
        if let Some(khz) = read_f64(p) {
            sum += khz;
            n += 1;
            hi = hi.max(khz);
        }
    }
    if n == 0 {
        return (0.0, 0.0);
    }
    (sum / n as f64 / 1e6, hi / 1e6)
}

fn cpu_power(cpu: &Cpu, prev: &mut Option<(i64, u64)>) -> f64 {
    if cpu.energy.is_empty() {
        *prev = None;
        return 0.0;
    }
    let cur = match read_u64(&cpu.energy) {
        Some(v) => v,
        None => return 0.0,
    };
    let now = now_ms();
    let watts = match prev.take() {
        Some((t, e)) if now > t => {
            let dj = if cur >= e { cur - e } else { cpu.energy_max.saturating_sub(e) + cur };
            dj as f64 / 1e6 / ((now - t) as f64 / 1000.0)
        }
        _ => 0.0,
    };
    *prev = Some((now, cur));
    watts
}

fn cpu_info_json(cpu: &Cpu) -> String {
    let model = std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("model name"))
                .and_then(|l| l.split_once(':'))
                .map(|(_, v)| v.trim().to_string())
        })
        .unwrap_or_default();
    format!(
        "{{\"model\":\"{}\",\"threads\":{},\"max_ghz\":{},\"temps\":[{}]}}",
        json_escape(&model),
        cpu.cur_freq.len(),
        fnum(read_u64(&cpu.max_freq).unwrap_or(0) as f64 / 1e6),
        cpu.temps
            .iter()
            .map(|(l, _)| format!("\"{}\"", json_escape(l)))
            .collect::<Vec<_>>()
            .join(",")
    )
}

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

struct Shared {
    smi: String,
    gpu_name: String,
    driver: String,
    /// Power-cap range from power.min_limit/max_limit; (0,0) = unsupported.
    cap_min: f64,
    cap_max: f64,
    /// Estimated DC-load budget in watts for the UI to flag against; 0 = off.
    budget: f64,
    /// SMBIOS RAM bus speed (static), empty = unknown.
    ram: String,
    seq: AtomicU64,
    cur: Mutex<String>,
    history: Mutex<VecDeque<String>>,
    cpu_info: String,
}

impl Shared {
    fn control_json(&self, cur: &str) -> String {
        let mut cap = 0.0f64;
        // power_limit is part of the sample JSON; read it back out.
        if let Some(i) = cur.find("\"power_limit\":") {
            let rest = &cur[i + 14..];
            let end = rest.find([',', '}']).unwrap_or(rest.len());
            cap = rest[..end].parse().unwrap_or(0.0);
        }
        format!(
            "{{\"ok\":{},\"cap\":{},\"cap_min\":{},\"cap_max\":{},\"budget\":{},\
             \"gpu\":\"{}\",\"driver\":\"{}\",\"ram\":\"{}\"}}",
            cur.contains("\"ok\":true"),
            fnum(cap),
            fnum(self.cap_min),
            fnum(self.cap_max),
            fnum(self.budget),
            json_escape(&self.gpu_name),
            json_escape(&self.driver),
            json_escape(&self.ram),
        )
    }
}

fn snapshot_json(sh: &Shared) -> String {
    let cur = sh.cur.lock().unwrap().clone();
    let hist = sh.history.lock().unwrap();
    format!(
        "{{\"now\":{},\"current\":{},\"history\":[{}],\"control\":{},\"cpu\":{}}}",
        now_ms(),
        cur,
        hist.iter().cloned().collect::<Vec<_>>().join(","),
        sh.control_json(&cur),
        sh.cpu_info,
    )
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

struct Req {
    method: String,
    path: String,
    body: String,
}

fn read_request(s: &mut TcpStream) -> Option<Req> {
    s.set_read_timeout(Some(Duration::from_secs(10))).ok()?;
    let mut reader = BufReader::new(s.try_clone().ok()?);
    let mut line = String::new();
    if reader.read_line(&mut line).ok()? == 0 {
        return None;
    }
    let mut parts = line.split_whitespace();
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();
    let mut content_len = 0usize;
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h).ok()? == 0 || h == "\r\n" || h == "\n" {
            break;
        }
        if let Some(v) = h.strip_prefix("Content-Length:").or_else(|| h.strip_prefix("content-length:")) {
            content_len = v.trim().parse().unwrap_or(0);
        }
    }
    let mut body = vec![0u8; content_len.min(64 * 1024)];
    if content_len > 0 {
        let _ = reader.read_exact(&mut body);
    }
    Some(Req { method, path, body: String::from_utf8_lossy(&body).to_string() })
}

fn send_bytes(s: &mut TcpStream, status: &str, ctype: &str, body: &[u8], extra: &str) {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\n\
         Access-Control-Allow-Origin: *\r\n{extra}\r\n",
        body.len()
    );
    let _ = s.write_all(head.as_bytes()).and_then(|_| s.write_all(body)).and_then(|_| s.flush());
}

fn send_json(s: &mut TcpStream, status: &str, body: &str) {
    send_bytes(s, status, "application/json", body.as_bytes(), "Cache-Control: no-store\r\n");
}

fn send_text(s: &mut TcpStream, status: &str, body: &str) {
    send_bytes(s, status, "text/plain; charset=utf-8", body.as_bytes(), "");
}

fn sse_stream(mut s: TcpStream, sh: Arc<Shared>) {
    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nX-Accel-Buffering: no\r\nConnection: keep-alive\r\n\r\n";
    if s.write_all(head.as_bytes()).is_err() {
        return;
    }
    let _ = s.flush();
    let mut last_seq = 0u64;
    let mut last_beat = now_ms();
    loop {
        let seq = sh.seq.load(Ordering::SeqCst);
        if seq != last_seq {
            last_seq = seq;
            let cur = sh.cur.lock().unwrap().clone();
            let ev = format!("data: {}\n\n", cur);
            if s.write_all(ev.as_bytes()).is_err() || s.flush().is_err() {
                return;
            }
        } else if now_ms() - last_beat > 15000 {
            if s.write_all(b": keep-alive\n\n").is_err() || s.flush().is_err() {
                return;
            }
            last_beat = now_ms();
        }
        thread::sleep(Duration::from_millis(200));
    }
}

/// Pull `"cap": <number>` out of the flat POST body.
fn body_cap(body: &str) -> Option<f64> {
    let i = body.find("\"cap\"")?;
    let rest = body[i + 5..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let end = rest.find([',', '}', ' ']).unwrap_or(rest.len());
    rest[..end].parse().ok()
}

fn handle(mut s: TcpStream, sh: Arc<Shared>) {
    let Some(req) = read_request(&mut s) else { return };
    let path = req.path.split('?').next().unwrap_or("/").to_string();

    if req.method == "GET" {
        match path.as_str() {
            "/" | "/index.html" => send_bytes(&mut s, "200 OK", "text/html; charset=utf-8", INDEX_HTML.as_bytes(), "Cache-Control: no-store\r\n"),
            "/app.js" => send_bytes(&mut s, "200 OK", "application/javascript; charset=utf-8", APP_JS.as_bytes(), "Cache-Control: no-store\r\n"),
            "/style.css" => send_bytes(&mut s, "200 OK", "text/css; charset=utf-8", STYLE_CSS.as_bytes(), "Cache-Control: no-store\r\n"),
            "/api/snapshot" => {
                let body = snapshot_json(&sh);
                send_json(&mut s, "200 OK", &body);
            }
            "/api/stream" => sse_stream(s, sh),
            "/api/health" => send_json(&mut s, "200 OK", &sh.control_json(&sh.cur.lock().unwrap().clone())),
            _ => send_text(&mut s, "404 Not Found", "not found"),
        }
        return;
    }

    if req.method == "POST" && path == "/api/power" {
        match body_cap(&req.body) {
            Some(w) if sh.cap_max > 0.0 && w >= sh.cap_min && w <= sh.cap_max => {
                match nvidia_smi(&sh.smi, &["-pl", &w.to_string()]) {
                    Ok(msg) => {
                        log(&format!("power cap set to {w} W: {}", msg.replace('\n', " ")));
                        let cur = sh.cur.lock().unwrap().clone();
                        send_json(&mut s, "200 OK", &format!("{{\"ok\":true,\"message\":\"{}\",\"control\":{}}}", json_escape(&msg.replace('\n', " ")), sh.control_json(&cur)));
                    }
                    Err(e) => {
                        log(&format!("power cap failed: {e}"));
                        send_json(&mut s, "400 Bad Request", &format!("{{\"ok\":false,\"error\":\"{}\"}}", json_escape(&e)));
                    }
                }
            }
            Some(_) => send_json(&mut s, "400 Bad Request", &format!("{{\"ok\":false,\"error\":\"cap out of range {:.0}–{:.0} W\"}}", sh.cap_min, sh.cap_max)),
            None => send_json(&mut s, "400 Bad Request", "{\"ok\":false,\"error\":\"no numeric cap in body\"}"),
        }
        return;
    }

    if req.method != "POST" && req.method != "OPTIONS" {
        send_text(&mut s, "405 Method Not Allowed", "method not allowed");
    } else {
        send_text(&mut s, "404 Not Found", "not found");
    }
}

// ---------------------------------------------------------------------------
// Embedded frontend
// ---------------------------------------------------------------------------

const INDEX_HTML: &str = include_str!("index.html");
const APP_JS: &str = include_str!("app.js");
const STYLE_CSS: &str = include_str!("style.css");

// ---------------------------------------------------------------------------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut listen = "0.0.0.0:7397".to_string();
    let mut smi = String::new();
    let mut interval_ms: u64 = 2000;
    let mut budget: f64 = 0.0;
    let mut dmi = String::new();

    let mut i = 1;
    while i < args.len() {
        let flag = args[i].clone();
        if flag == "--listen" || flag == "--nvidia-smi" || flag == "--interval" || flag == "--budget" || flag == "--dmidecode" {
            i += 1;
            let v = args.get(i).cloned().unwrap_or_default();
            match flag.as_str() {
                "--listen" => listen = v,
                "--nvidia-smi" => smi = v,
                "--interval" => interval_ms = v.parse().unwrap_or(2000).clamp(500, 60_000),
                "--budget" => budget = v.parse().unwrap_or(0.0),
                "--dmidecode" => dmi = v,
                _ => unreachable!(),
            }
        } else if flag == "--help" || flag == "-h" {
            println!(
                "usage: fah-panel [--listen ADDR:PORT] --nvidia-smi PATH [--interval MS]\n\
                 [--budget W] [--dmidecode PATH]\n\
                 The power cap is live state: whatever nvidia-smi reports is truth, and\n\
                 a boot-time systemd unit (not this panel) owns setting it at startup.\n\
                 --budget flags the CPU+GPU DC-load estimate above W (brownout margin);\n\
                 --dmidecode reads the SMBIOS RAM bus speed once at startup (root)."
            );
            return;
        } else {
            eprintln!("fah-panel: unknown argument {flag}");
            std::process::exit(2);
        }
        i += 1;
    }
    if smi.is_empty() {
        eprintln!("fah-panel: --nvidia-smi PATH is required (absolute store path)");
        std::process::exit(2);
    }

    let gpu_name = nvidia_smi(&smi, &["--query-gpu=name", "--format=csv,noheader"])
        .unwrap_or_else(|e| {
            eprintln!("fah-panel: nvidia-smi not usable yet: {e}");
            "NVIDIA GPU".into()
        })
        .lines()
        .next()
        .unwrap_or("NVIDIA GPU")
        .to_string();
    let driver = nvidia_smi(&smi, &["--query-gpu=driver_version", "--format=csv,noheader"])
        .unwrap_or_default()
        .lines()
        .next()
        .unwrap_or_default()
        .to_string();
    // Power-cap range; "N/A" fields (no support) become (0, 0) -> slider hidden.
    let (cap_min, cap_max) =
        match nvidia_smi(&smi, &["--query-gpu=power.min_limit,power.max_limit", "--format=csv,noheader,nounits"]) {
            Ok(line) => {
                let f: Vec<&str> = line.lines().next().unwrap_or("").split(',').map(|c| c.trim()).collect();
                (f.first().and_then(|v| v.parse().ok()).unwrap_or(0.0), f.get(1).and_then(|v| v.parse().ok()).unwrap_or(0.0))
            }
            Err(_) => (0.0, 0.0),
        };

    let cpu = detect_cpu();
    let sh = Arc::new(Shared {
        smi,
        gpu_name: gpu_name.clone(),
        driver,
        cap_min,
        cap_max,
        budget,
        ram: ram_speed(&dmi),
        seq: AtomicU64::new(0),
        cur: Mutex::new(Sample::default().to_json()),
        history: Mutex::new(VecDeque::with_capacity(601)),
        cpu_info: cpu_info_json(&cpu),
    });
    log(&format!(
        "fah-panel: gpu={gpu_name} caps=({cap_min},{cap_max}) ram=\"{}\" listen={listen} cpu_threads={}",
        sh.ram,
        cpu.cur_freq.len()
    ));

    // Sampler: nvidia-smi poll + CPU sysfs; the CPU numbers ride along in a
    // side JSON so the stream carries everything one sample needs.
    let sh2 = Arc::clone(&sh);
    thread::Builder::new()
        .name("sampler".into())
        .spawn(move || {
            let mut rapl: Option<(i64, u64)> = None;
            loop {
                let mut s = take_sample(&sh2.smi);
                s.cpu_temp = cpu_pkg_temp(&cpu);
                let hot = cpu_temp_by(&cpu, "Core");
                let (clk_avg, clk_max) = cpu_clocks(&cpu);
                s.cpu_power = cpu_power(&cpu, &mut rapl);
                s.total = s.power + s.cpu_power;
                let mut j = s.to_json();
                // Splice the remaining CPU fields the sparklines do not need.
                j.pop();
                j.push_str(&format!(
                    ",\"cpu_hot\":{},\"cpu_clk_avg\":{},\"cpu_clk_max\":{}}}",
                    fnum_pos(hot),
                    fnum(clk_avg),
                    fnum(clk_max),
                ));
                *sh2.cur.lock().unwrap() = j.clone();
                {
                    let mut h = sh2.history.lock().unwrap();
                    h.push_back(j);
                    while h.len() > 600 {
                        h.pop_front();
                    }
                }
                sh2.seq.fetch_add(1, Ordering::SeqCst);
                thread::sleep(Duration::from_millis(interval_ms));
            }
        })
        .expect("spawn sampler");

    let listener = match TcpListener::bind(&listen) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("fah-panel: bind {listen}: {e}");
            std::process::exit(1);
        }
    };
    log(&format!("fah-panel: listening on {listen}"));
    for conn in listener.incoming() {
        match conn {
            Ok(s) => {
                let sh3 = Arc::clone(&sh);
                thread::Builder::new().spawn(move || handle(s, sh3)).ok();
            }
            Err(e) => log(&format!("accept: {e}")),
        }
    }
}
