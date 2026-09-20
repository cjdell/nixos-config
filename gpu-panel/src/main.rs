//! gpu-panel — GPU telemetry + control web panel for zen3-nixos.
//!
//! Reads *all* monitoring data natively from sysfs (temps, fan, power,
//! clocks, utilisation, VRAM) and keeps a rolling history in memory.
//! Serves a live web dashboard (embedded HTML/JS/CSS, canvas charts, SSE
//! stream) plus JSON control endpoints.
//!
//! Writes (fan curve / power cap / clocks / voltage / performance level) are
//! delegated to the LACT daemon over its unix socket. LACT is the component
//! that owns the SMU/overdrive plumbing and its "unconfirmed change
//! auto-revert" safety timer; duplicating that logic here would be strictly
//! more dangerous. gpu-panel sets a value and immediately confirms it, or
//! forwards an explicit revert.
//!
//! Zero dependencies: Rust std only.

use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn log(msg: &str) {
    eprintln!("[gpu-panel] {msg}");
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
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

fn fnum(v: f64) -> String {
    if v.is_finite() {
        format!("{v:.3}")
    } else {
        "null".to_string()
    }
}

fn read_trim(path: &str) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn read_u64(path: &str) -> Option<u64> {
    read_trim(path)?.parse().ok()
}

fn read_f64(path: &str) -> Option<f64> {
    read_trim(path)?.parse().ok()
}

/// Current level of a `pp_dpm_*` table: the `*`-marked line, e.g.
/// `1: 500Mhz *` or `S: 0Mhz *` (the "S" entry is the SMU idle state).
fn dpm_current(path: &str) -> u32 {
    let Some(text) = read_trim(path) else {
        return 0;
    };
    for line in text.lines() {
        if !line.contains('*') {
            continue;
        }
        let after_colon = line.split(':').nth(1).unwrap_or("");
        let digits: String = after_colon
            .trim()
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        return digits.parse().unwrap_or(0);
    }
    0
}

// ---------------------------------------------------------------------------
// Minimal JSON (parse + navigate). Serialising is done with format!.
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(kv) => kv.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
    fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }
    fn as_i64(&self) -> Option<i64> {
        self.as_f64().map(|n| n as i64)
    }
    fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }
    fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }
    fn as_arr(&self) -> Option<&[Json]> {
        match self {
            Json::Arr(a) => Some(a),
            _ => None,
        }
    }
    fn entries(&self) -> Vec<(&String, &Json)> {
        match self {
            Json::Obj(kv) => kv.iter().map(|(k, v)| (k, v)).collect(),
            _ => Vec::new(),
        }
    }
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn ws(&mut self) {
        while self.i < self.b.len() && (self.b[self.i] as char).is_whitespace() {
            self.i += 1;
        }
    }
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }
    fn value(&mut self) -> Option<Json> {
        self.ws();
        match self.peek()? {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => self.string().map(Json::Str),
            b't' | b'f' => self.literal_bool().map(Json::Bool),
            b'n' => self.literal_null(),
            _ => self.number(),
        }
    }
    fn object(&mut self) -> Option<Json> {
        self.i += 1; // {
        let mut out = Vec::new();
        loop {
            self.ws();
            match self.peek()? {
                b'}' => {
                    self.i += 1;
                    return Some(Json::Obj(out));
                }
                b',' => {
                    self.i += 1;
                    continue;
                }
                b'"' => {
                    let k = self.string()?;
                    self.ws();
                    if self.peek()? != b':' {
                        return None;
                    }
                    self.i += 1;
                    let v = self.value()?;
                    out.push((k, v));
                }
                _ => return None,
            }
        }
    }
    fn array(&mut self) -> Option<Json> {
        self.i += 1; // [
        let mut out = Vec::new();
        loop {
            self.ws();
            match self.peek()? {
                b']' => {
                    self.i += 1;
                    return Some(Json::Arr(out));
                }
                b',' => {
                    self.i += 1;
                    continue;
                }
                _ => out.push(self.value()?),
            }
        }
    }
    fn string(&mut self) -> Option<String> {
        if self.peek()? != b'"' {
            return None;
        }
        self.i += 1;
        let mut out = String::new();
        loop {
            let c = self.peek()?;
            self.i += 1;
            match c {
                b'"' => return Some(out),
                b'\\' => {
                    let e = self.peek()?;
                    self.i += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let hex: String = self.b.get(self.i..self.i + 4)?
                                .iter()
                                .map(|b| *b as char)
                                .collect();
                            self.i += 4;
                            let cp = u32::from_str_radix(&hex, 16).ok()?;
                            out.push(char::from_u32(cp).unwrap_or('\u{fffd}'));
                        }
                        _ => return None,
                    }
                }
                _ => out.push(c as char),
            }
        }
    }
    fn literal_bool(&mut self) -> Option<bool> {
        if self.b[self.i..].starts_with(b"true") {
            self.i += 4;
            Some(true)
        } else if self.b[self.i..].starts_with(b"false") {
            self.i += 5;
            Some(false)
        } else {
            None
        }
    }
    fn literal_null(&mut self) -> Option<Json> {
        if self.b[self.i..].starts_with(b"null") {
            self.i += 4;
            Some(Json::Null)
        } else {
            None
        }
    }
    fn number(&mut self) -> Option<Json> {
        let start = self.i;
        while self.i < self.b.len() {
            let c = self.b[self.i] as char;
            if c.is_ascii_digit() || "+-.eE".contains(c) {
                self.i += 1;
            } else {
                break;
            }
        }
        let s = std::str::from_utf8(&self.b[start..self.i]).ok()?;
        s.parse::<f64>().ok().map(Json::Num)
    }
}

fn parse_json(s: &str) -> Option<Json> {
    let mut p = Parser { b: s.as_bytes(), i: 0 };
    let v = p.value()?;
    Some(v)
}

// ---------------------------------------------------------------------------
// GPU paths (resolved by PCI BDF — DRM card numbers change between boots)
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Paths {
    dev: String,
    hwmon: String,
    /// hwmon temperature inputs keyed by their label ("edge"/"junction"/"mem").
    temps: Vec<(String, String)>,
    vddgfx: String,
    /// amdgpu SMU overdrive fan-control dir (RDNA3+); empty when unavailable.
    fan_ctrl: String,
}

fn resolve_paths(bdf: &str) -> Result<Paths, String> {
    let dev = format!("/sys/bus/pci/devices/{bdf}");
    if !std::path::Path::new(&dev).exists() {
        return Err(format!("no such PCI device: {dev}"));
    }
    let hwmon = std::fs::read_dir(format!("{dev}/hwmon"))
        .map_err(|e| format!("{dev}/hwmon: {e}"))?
        .flatten()
        .map(|e| format!("{dev}/hwmon/{}", e.file_name().to_string_lossy()))
        .find(|p| std::path::Path::new(&format!("{p}/power1_average")).exists())
        .ok_or_else(|| format!("no amdgpu hwmon under {dev}"))?;

    let mut temps = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&hwmon) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            // Only temperature channels; the same directory also exposes
            // freq*_input (sclk/mclk) and in0_input (vddgfx) with labels.
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

    let vddgfx = format!("{hwmon}/in0_input");
    let fan_ctrl = format!("{dev}/gpu_od/fan_ctrl");
    let fan_ctrl = if std::path::Path::new(&format!("{fan_ctrl}/fan_curve")).exists() {
        fan_ctrl
    } else {
        String::new()
    };
    Ok(Paths {
        dev,
        hwmon,
        temps,
        vddgfx,
        fan_ctrl,
    })
}

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Sample {
    t: i64,
    edge: f64,
    hotspot: f64,
    mem_temp: f64,
    fan_rpm: u32,
    fan_pwm: u32,
    power: f64,
    cap: f64,
    sclk: u32,
    mclk: u32,
    volt: u32,
    gpu_busy: u32,
    mem_busy: u32,
    vram_used: u64,
    vram_total: u64,
    gtt_used: u64,
    gtt_total: u64,
    perf: String,
    /// Panel PID controller state: commanded duty (-1 when inactive),
    /// the measured control temperature and the current target.
    fan_cmd: i32,
    ctrl_temp: f64,
    target: f64,
}

impl Sample {
    fn to_json(&self) -> String {
        format!(
            "{{\"t\":{},\"edge\":{},\"hotspot\":{},\"mem_temp\":{},\"fan_rpm\":{},\"fan_pwm\":{},\"power\":{},\"cap\":{},\"sclk\":{},\"mclk\":{},\"volt\":{},\"gpu_busy\":{},\"mem_busy\":{},\"vram_used\":{},\"vram_total\":{},\"gtt_used\":{},\"gtt_total\":{},\"perf\":\"{}\",\"fan_cmd\":{},\"ctrl_temp\":{},\"target\":{}}}",
            self.t, fnum(self.edge), fnum(self.hotspot), fnum(self.mem_temp),
            self.fan_rpm, self.fan_pwm, fnum(self.power), fnum(self.cap),
            self.sclk, self.mclk, self.volt, self.gpu_busy, self.mem_busy,
            self.vram_used, self.vram_total, self.gtt_used, self.gtt_total,
            json_escape(&self.perf), self.fan_cmd, fnum(self.ctrl_temp), fnum(self.target)
        )
    }
}

fn temp_by_label(p: &Paths, label: &str) -> f64 {
    p.temps
        .iter()
        .find(|(l, _)| l == label)
        .and_then(|(_, path)| read_f64(path))
        .map(|v| v / 1000.0)
        .unwrap_or(0.0)
}

fn take_sample(p: &Paths) -> Sample {
    let pwm = read_u64(&format!("{}/pwm1", p.hwmon)).unwrap_or(0);
    Sample {
        t: now_ms(),
        edge: temp_by_label(p, "edge"),
        hotspot: temp_by_label(p, "junction"),
        mem_temp: temp_by_label(p, "mem"),
        fan_rpm: read_u64(&format!("{}/fan1_input", p.hwmon)).unwrap_or(0) as u32,
        fan_pwm: pwm as u32,
        power: read_f64(&format!("{}/power1_average", p.hwmon)).unwrap_or(0.0) / 1_000_000.0,
        cap: read_f64(&format!("{}/power1_cap", p.hwmon)).unwrap_or(0.0) / 1_000_000.0,
        sclk: dpm_current(&format!("{}/pp_dpm_sclk", p.dev)),
        mclk: dpm_current(&format!("{}/pp_dpm_mclk", p.dev)),
        volt: read_u64(&p.vddgfx).unwrap_or(0) as u32,
        gpu_busy: read_u64(&format!("{}/gpu_busy_percent", p.dev)).unwrap_or(0) as u32,
        mem_busy: read_u64(&format!("{}/mem_busy_percent", p.dev)).unwrap_or(0) as u32,
        vram_used: read_u64(&format!("{}/mem_info_vram_used", p.dev)).unwrap_or(0),
        vram_total: read_u64(&format!("{}/mem_info_vram_total", p.dev)).unwrap_or(0),
        gtt_used: read_u64(&format!("{}/mem_info_gtt_used", p.dev)).unwrap_or(0),
        gtt_total: read_u64(&format!("{}/mem_info_gtt_total", p.dev)).unwrap_or(0),
        perf: read_trim(&format!("{}/power_dpm_force_performance_level", p.dev))
            .unwrap_or_else(|| "auto".to_string()),
        fan_cmd: -1,
        ctrl_temp: 0.0,
        target: 0.0,
    }
}

// ---------------------------------------------------------------------------
// Fan control: direct SMU overdrive fan curve + PID thermal loop
// ---------------------------------------------------------------------------
//
// On RDNA3+ the only writable fan interface is the SMU overdrive curve
// (`gpu_od/fan_ctrl/fan_curve`): write `"<idx> <temp> <pwm%>"` per anchor and
// `"c"` to commit (this switches PMFW to manual fan control), or `"r"` to
// reset and hand control back to the firmware.
//
// The PID loop commands a duty cycle, but instead of flattening all five
// anchors to that duty it writes a *rising* curve centred on the target
// temperature. That gives the loop authority near the setpoint while leaving
// a firmware-side ramp above it -- so if this process dies with the fan at a
// low duty, the GPU still cools itself as the temperature climbs.

fn write_file_retry(path: &str, data: &str) -> Result<(), String> {
    let mut last = String::new();
    for attempt in 0..4 {
        match std::fs::write(path, data.as_bytes()) {
            Ok(_) => return Ok(()),
            Err(e) => {
                last = e.to_string();
                thread::sleep(Duration::from_millis(20 * (attempt + 1)));
            }
        }
    }
    Err(format!("{path}: {last}"))
}

/// Write a full 5-point curve and commit it (switches PMFW to manual mode).
fn write_fan_curve(ctrl: &str, points: &[(i32, f64)]) -> Result<(), String> {
    if ctrl.is_empty() {
        return Err("no overdrive fan-control interface on this GPU".into());
    }
    let f = format!("{ctrl}/fan_curve");
    for (i, (t, s)) in points.iter().enumerate() {
        write_file_retry(&f, &format!("{i} {t} {}\n", s.round() as i64))?;
        thread::sleep(Duration::from_millis(30));
    }
    write_file_retry(&f, "c\n")?;
    Ok(())
}

/// Give fan control back to the GPU firmware (default curve / auto mode).
fn reset_fan_curve(ctrl: &str) -> Result<(), String> {
    if ctrl.is_empty() {
        return Ok(());
    }
    write_file_retry(&format!("{ctrl}/fan_curve"), "r\n")
}

fn fan_source_temp(p: &Paths, source: &str) -> f64 {
    match source {
        "junction" => temp_by_label(p, "junction"),
        "mem" => temp_by_label(p, "mem"),
        _ => temp_by_label(p, "edge"),
    }
}

/// Curve for a PID duty `duty` with the anchor at `center_hotspot` (the
/// firmware evaluates the overdrive curve against the *hotspot* sensor, so
/// the caller passes `target + (hotspot - source)`): `duty` at the centre,
/// lower below it, and a firmware ramp to 100% above it.
fn build_pid_curve(center_hotspot: f64, duty: f64, duty_min: f64) -> Vec<(i32, f64)> {
    let t = center_hotspot.clamp(25.0, 100.0);
    // Spread the two anchors above the centre over the remaining range up to
    // the SMU curve's 100 C x-axis end. Fixed `t+5`/`t+15` offsets collapse
    // onto each other once the centre passes ~85 C, and duplicate anchor
    // temperatures make the upper ramp unreachable for the firmware.
    let room = (100.0 - t).max(0.0);
    let candidates = [t - 20.0, t - 10.0, t, t + room * 0.5, 100.0];
    let mut temps: Vec<i32> = Vec::with_capacity(5);
    for c in candidates {
        let mut v = c.clamp(25.0, 100.0);
        if let Some(prev) = temps.last() {
            if v <= *prev as f64 {
                v = *prev as f64 + 1.0;
            }
        }
        temps.push(v.min(100.0) as i32);
    }
    let mut speeds = [
        duty - 20.0,
        duty - 8.0,
        duty,
        duty + (100.0 - duty) * 0.5,
        100.0,
    ];
    // Clamp into [duty_min, 100] and force non-decreasing.
    let mut prev = duty_min;
    for s in speeds.iter_mut() {
        let v = s.clamp(duty_min, 100.0).max(prev);
        *s = v;
        prev = v;
    }
    temps
        .into_iter()
        .zip(speeds.iter())
        .map(|(t, s)| (t, *s))
        .collect()
}

#[derive(Clone)]
struct Thermal {
    // configuration
    enabled: bool,
    target: f64,
    source: String,
    kp: f64,
    ki: f64,
    kd: f64,
    duty_min: f64,
    duty_max: f64,
    interval_ms: u64,
    // live runtime
    active: bool,
    measured: f64,
    error: f64,
    duty: f64,
    integral: f64,
    /// Hotspot-space centre of the written curve (target + sensor offset).
    center: f64,
    /// Duty/centre actually pushed to the firmware (for change detection).
    last_write_duty: f64,
    last_write_center: f64,
    last_meas: Option<f64>,
    last_t_ms: i64,
    last_update_ms: i64,
    writes: u64,
    last_error: String,
    /// LACT fan control has been released to the panel (one-shot handshake).
    handed_off: bool,
}

impl Default for Thermal {
    fn default() -> Self {
        Thermal {
            enabled: false,
            target: 85.0,
            // `junction` (hotspot) is both the sensor the SMU evaluates the
            // overdrive curve against and the one that actually limits the
            // card. Regulating `edge` instead lets the hotspot run ~25-30 C
            // hotter than the setpoint (see hotspot_floor below).
            source: "junction".into(),
            kp: 4.0,
            ki: 0.4,
            kd: 1.5,
            duty_min: 25.0,
            duty_max: 100.0,
            interval_ms: 1000,
            active: false,
            measured: 0.0,
            error: 0.0,
            duty: 0.0,
            integral: 0.0,
            center: 0.0,
            last_write_duty: -1.0,
            last_write_center: -1.0,
            last_meas: None,
            last_t_ms: 0,
            last_update_ms: 0,
            writes: 0,
            last_error: String::new(),
            handed_off: false,
        }
    }
}

impl Thermal {
    fn to_json(&self) -> String {
        format!(
            "{{\"enabled\":{},\"active\":{},\"target\":{},\"source\":\"{}\",\"kp\":{},\"ki\":{},\"kd\":{},\"duty_min\":{},\"duty_max\":{},\"interval_ms\":{},\"measured\":{},\"error\":{},\"duty\":{},\"integral\":{},\"center\":{},\"last_update_ms\":{},\"writes\":{},\"last_error\":\"{}\"}}",
            self.enabled,
            self.active,
            fnum(self.target),
            json_escape(&self.source),
            fnum(self.kp),
            fnum(self.ki),
            fnum(self.kd),
            fnum(self.duty_min),
            fnum(self.duty_max),
            self.interval_ms,
            fnum(self.measured),
            fnum(self.error),
            fnum(self.duty),
            fnum(self.integral),
            fnum(self.center),
            self.last_update_ms,
            self.writes,
            json_escape(&self.last_error)
        )
    }

    fn apply_json(&mut self, j: &Json) {
        if let Some(v) = j.get("target").and_then(|v| v.as_f64()) {
            self.target = v.clamp(25.0, 100.0);
        }
        if let Some(v) = j.get("source").and_then(|v| v.as_str()) {
            if matches!(v, "edge" | "junction" | "mem") {
                self.source = v.to_string();
            }
        }
        if let Some(v) = j.get("kp").and_then(|v| v.as_f64()) {
            self.kp = v.clamp(0.0, 50.0);
        }
        if let Some(v) = j.get("ki").and_then(|v| v.as_f64()) {
            self.ki = v.clamp(0.0, 10.0);
        }
        if let Some(v) = j.get("kd").and_then(|v| v.as_f64()) {
            self.kd = v.clamp(0.0, 50.0);
        }
        if let Some(v) = j.get("duty_min").and_then(|v| v.as_f64()) {
            self.duty_min = v.clamp(0.0, 100.0);
        }
        if let Some(v) = j.get("duty_max").and_then(|v| v.as_f64()) {
            self.duty_max = v.clamp(self.duty_min, 100.0);
        }
        if let Some(v) = j.get("interval_ms").and_then(|v| v.as_f64()) {
            self.interval_ms = (v as u64).clamp(250, 10000);
        }
    }

    fn reset_loop(&mut self) {
        self.integral = 0.0;
        self.last_meas = None;
        self.last_t_ms = 0;
        self.last_write_duty = -1.0;
        self.last_write_center = -1.0;
    }

    fn disarm(&mut self) {
        self.enabled = false;
        self.active = false;
        self.handed_off = false;
        self.duty = 0.0;
        self.reset_loop();
    }

    /// Hotspot safety floor, applied independently of the regulated sensor.
    ///
    /// Under load the hotspot runs ~25-30 C hotter than `edge` (and ~10 C
    /// hotter than `mem`), so a loop regulating one of those sensors can sit
    /// at minimum duty while the junction approaches its limit -- the firmware
    /// ramp inside the written curve is then the only thing cooling the card.
    /// This floor ramps duty from `duty_min` at 90 C to `duty_max` at 100 C, so
    /// the junction is protected no matter which feedback sensor is selected.
    fn hotspot_floor(&self, hotspot: f64) -> f64 {
        const KNEE: f64 = 90.0;
        const TRIP: f64 = 100.0;
        if !hotspot.is_finite() || hotspot <= KNEE {
            return self.duty_min;
        }
        let frac = ((hotspot - KNEE) / (TRIP - KNEE)).clamp(0.0, 1.0);
        self.duty_min + frac * (self.duty_max - self.duty_min)
    }

    /// One PID step. Returns the new duty cycle (%).
    fn step(&mut self, measured: f64, hotspot: f64, now: i64) -> f64 {
        let dt = if self.last_t_ms == 0 {
            1.0
        } else {
            ((now - self.last_t_ms) as f64 / 1000.0).clamp(0.2, 10.0)
        };
        self.last_t_ms = now;
        let err = measured - self.target;
        let dmeas = match self.last_meas {
            Some(m) => (measured - m) / dt,
            None => 0.0,
        };
        self.last_meas = Some(measured);
        // Anti-windup: cap the integral term at the output span (the old fixed
        // +/-300 C*s let `ki * integral` reach +/-120 %, so a railed loop took
        // minutes to unwind once the error changed sign).
        let i_limit = if self.ki > 0.0 {
            (self.duty_max - self.duty_min) / self.ki
        } else {
            0.0
        };
        self.integral = (self.integral + err * dt).clamp(-i_limit, i_limit);
        let mut out = self.kp * err + self.ki * self.integral + self.kd * dmeas;
        // Hard safety: well above the setpoint -> full speed regardless.
        // Checked on the hotspot too, since that is what the curve is graded
        // against and `measured` may be a much cooler sensor.
        if measured >= 100.0 || hotspot >= 100.0 {
            out = 100.0;
        }
        // Max-select: whichever of the PID or the hotspot guard wants more fan
        // wins, so the guard can only ever add duty, never remove it.
        out = out.max(self.hotspot_floor(hotspot));
        let clamped = out.clamp(self.duty_min, self.duty_max.min(100.0));
        self.measured = measured;
        self.error = err;
        self.duty = clamped;
        clamped
    }
}

fn thermal_save(path: &str, t: &Thermal) {
    let body = format!(
        "{{\"enabled\":{},\"target\":{},\"source\":\"{}\",\"kp\":{},\"ki\":{},\"kd\":{},\"duty_min\":{},\"duty_max\":{},\"interval_ms\":{}}}",
        t.enabled,
        fnum(t.target),
        json_escape(&t.source),
        fnum(t.kp),
        fnum(t.ki),
        fnum(t.kd),
        fnum(t.duty_min),
        fnum(t.duty_max),
        t.interval_ms
    );
    if let Some(dir) = std::path::Path::new(path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Err(e) = std::fs::write(path, body) {
        log(&format!("could not save thermal state to {path}: {e}"));
    }
}

fn thermal_load(path: &str) -> Option<Thermal> {
    let text = std::fs::read_to_string(path).ok()?;
    let j = parse_json(&text)?;
    let mut t = Thermal::default();
    t.apply_json(&j);
    t.enabled = j.get("enabled").and_then(|v| v.as_bool()).unwrap_or(false);
    Some(t)
}

// --- graceful shutdown -----------------------------------------------------

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

extern "C" {
    fn signal(n: i32, handler: usize) -> usize;
}

const SIGINT: i32 = 2;
const SIGTERM: i32 = 15;

/// Signal handler: only flips a flag (nothing else is async-signal-safe).
extern "C" fn on_signal(_sig: i32) {
    SHUTDOWN.store(true, Ordering::SeqCst);
}

// ---------------------------------------------------------------------------
// LACT control channel
// ---------------------------------------------------------------------------

fn lact_call(sock: &str, req: &str, timeout: Duration) -> Result<Json, String> {
    let mut s = UnixStream::connect(sock).map_err(|e| format!("connect {sock}: {e}"))?;
    let _ = s.set_read_timeout(Some(timeout));
    let _ = s.set_write_timeout(Some(timeout));
    s.write_all(req.as_bytes())
        .and_then(|_| s.write_all(b"\n"))
        .map_err(|e| format!("write: {e}"))?;

    let mut buf = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    loop {
        match s.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.contains(&b'\n') {
                    break;
                }
            }
            Err(e) => return Err(format!("read: {e}")),
        }
    }
    let text = String::from_utf8_lossy(&buf).trim().to_string();
    let j = parse_json(&text).ok_or_else(|| format!("bad JSON from LACT: {text}"))?;
    match j.get("status").and_then(|s| s.as_str()) {
        Some("ok") => Ok(j.get("data").cloned().unwrap_or(Json::Null)),
        _ => {
            // Error payloads are usually {"description": "...", "source": {...}}.
            let desc = j
                .get("data")
                .and_then(|d| d.get("description").and_then(|s| s.as_str()).map(String::from))
                .unwrap_or(text);
            Err(format!("LACT: {desc}"))
        }
    }
}

fn lact_confirm(sock: &str, confirm: bool) -> Result<(), String> {
    let cmd = if confirm { "confirm" } else { "revert" };
    let req = format!(
        "{{\"command\":\"confirm_pending_config\",\"args\":{{\"command\":\"{cmd}\"}}}}"
    );
    match lact_call(sock, &req, Duration::from_secs(5)) {
        Ok(_) => Ok(()),
        // "No pending config changes" after a successful set is fine.
        Err(e) if e.contains("No pending") => Ok(()),
        Err(e) => Err(e),
    }
}

/// Send a config command then confirm it, so the change is persisted by LACT
/// instead of being auto-reverted after its 5 s safety timer.
fn lact_set(sock: &str, req: &str) -> Result<(), String> {
    lact_call(sock, req, Duration::from_secs(10)).map_err(|e| {
        let _ = lact_confirm(sock, false);
        e
    })?;
    lact_confirm(sock, true)
}

// ---------------------------------------------------------------------------
// Control state (ranges + current settings), read from LACT
// ---------------------------------------------------------------------------

#[derive(Clone, Default)]
struct Range3 {
    cur: f64,
    min: f64,
    max: f64,
}

#[derive(Clone, Default)]
struct PmfwRange {
    cur: f64,
    min: f64,
    max: f64,
}

#[derive(Clone, Default)]
struct CtlState {
    ok: bool,
    error: String,
    fan_enabled: bool,
    fan_mode: String,
    fan_static: f64,
    fan_curve: Vec<(i32, f64)>,
    temp_key: String,
    temp_min: i32,
    temp_max: i32,
    pwm_min: f64,
    pwm_max: f64,
    acoustic_limit: PmfwRange,
    acoustic_target: PmfwRange,
    minimum_pwm: PmfwRange,
    target_temperature: PmfwRange,
    power: Range3,
    power_default: f64,
    perf_level: String,
    sclk_offset: Range3,
    mclk_min: Range3,
    mclk_max: Range3,
    volt_offset: Range3,
}

impl CtlState {
    fn to_json(&self) -> String {
        let curve = self
            .fan_curve
            .iter()
            .map(|(t, s)| format!("[{t},{}]", fnum(*s)))
            .collect::<Vec<_>>()
            .join(",");
        let r = |x: &Range3| {
            format!(
                "{{\"cur\":{},\"min\":{},\"max\":{}}}",
                fnum(x.cur),
                fnum(x.min),
                fnum(x.max)
            )
        };
        let p = |x: &PmfwRange| {
            format!(
                "{{\"cur\":{},\"min\":{},\"max\":{}}}",
                fnum(x.cur),
                fnum(x.min),
                fnum(x.max)
            )
        };
        format!(
            "{{\"ok\":{},\"error\":\"{}\",\"fan\":{{\"enabled\":{},\"mode\":\"{}\",\"static\":{},\"curve\":[{}],\"temperature_key\":\"{}\",\"temp_min\":{},\"temp_max\":{},\"pwm_min\":{},\"pwm_max\":{},\"acoustic_limit\":{},\"acoustic_target\":{},\"minimum_pwm\":{},\"target_temperature\":{}}},\"power\":{},\"power_default\":{},\"perf_level\":\"{}\",\"sclk_offset\":{},\"mclk_min\":{},\"mclk_max\":{},\"volt_offset\":{}}}",
            self.ok,
            json_escape(&self.error),
            self.fan_enabled,
            json_escape(&self.fan_mode),
            fnum(self.fan_static),
            curve,
            json_escape(&self.temp_key),
            self.temp_min,
            self.temp_max,
            fnum(self.pwm_min),
            fnum(self.pwm_max),
            p(&self.acoustic_limit),
            p(&self.acoustic_target),
            p(&self.minimum_pwm),
            p(&self.target_temperature),
            r(&self.power),
            fnum(self.power_default),
            json_escape(&self.perf_level),
            r(&self.sclk_offset),
            r(&self.mclk_min),
            r(&self.mclk_max),
            r(&self.volt_offset),
        )
    }
}

fn range_from(j: &Json, cur: f64) -> Range3 {
    let mn = j
        .get("min")
        .and_then(|v| v.as_f64())
        .unwrap_or(cur);
    let mx = j
        .get("max")
        .and_then(|v| v.as_f64())
        .unwrap_or(cur);
    Range3 { cur, min: mn, max: mx }
}

fn pmfw_pair(j: &Json) -> PmfwRange {
    let cur = j.get("current").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let rng = j.get("allowed_range");
    let min = rng
        .and_then(|r| r.as_arr())
        .and_then(|a| a.first())
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let max = rng
        .and_then(|r| r.as_arr())
        .and_then(|a| a.get(1))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    PmfwRange { cur, min, max }
}

fn fetch_ctl(sock: &str, id: &str) -> CtlState {
    let mut c = CtlState::default();
    c.fan_mode = "auto".into();
    c.perf_level = "auto".into();
    c.fan_static = 1.0;
    c.temp_key = "edge".into();

    let stats_req = format!(
        "{{\"command\":\"device_stats\",\"args\":{{\"id\":\"{}\"}}}}",
        json_escape(id)
    );
    let stats = match lact_call(sock, &stats_req, Duration::from_secs(5)) {
        Ok(j) => j,
        Err(e) => {
            c.error = e;
            return c;
        }
    };
    c.ok = true;

    if let Some(fan) = stats.get("fan") {
        c.fan_enabled = fan.get("control_enabled").and_then(|v| v.as_bool()).unwrap_or(false);
        if let Some(m) = fan.get("control_mode").and_then(|v| v.as_str()) {
            c.fan_mode = m.to_string();
        }
        if let Some(s) = fan.get("static_speed").and_then(|v| v.as_f64()) {
            c.fan_static = s;
        }
        if let Some(tk) = fan.get("temperature_key").and_then(|v| v.as_str()) {
            c.temp_key = tk.to_string();
        }
        if let Some(curve) = fan.get("curve") {
            let mut v: Vec<(i32, f64)> = curve
                .entries()
                .iter()
                .filter_map(|(k, s)| Some((k.parse::<i32>().ok()?, s.as_f64()?)))
                .collect();
            v.sort_by_key(|(t, _)| *t);
            c.fan_curve = v;
        }
        if let Some(r) = fan.get("temperature_range").and_then(|v| v.as_arr()) {
            c.temp_min = r.first().and_then(|v| v.as_i64()).unwrap_or(25) as i32;
            c.temp_max = r.get(1).and_then(|v| v.as_i64()).unwrap_or(100) as i32;
        }
        if let (Some(pmin), Some(pmax)) = (
            fan.get("pwm_min").and_then(|v| v.as_f64()),
            fan.get("pwm_max").and_then(|v| v.as_f64()),
        ) {
            c.pwm_min = pmin;
            c.pwm_max = pmax;
        }
        if let Some(pmfw) = fan.get("pmfw_info") {
            if let Some(v) = pmfw.get("acoustic_limit") {
                c.acoustic_limit = pmfw_pair(v);
            }
            if let Some(v) = pmfw.get("acoustic_target") {
                c.acoustic_target = pmfw_pair(v);
            }
            if let Some(v) = pmfw.get("minimum_pwm") {
                c.minimum_pwm = pmfw_pair(v);
            }
            if let Some(v) = pmfw.get("target_temp") {
                c.target_temperature = pmfw_pair(v);
            }
        }
    }

    if let Some(p) = stats.get("power") {
        let cur = p.get("cap_current").and_then(|v| v.as_f64()).unwrap_or(0.0);
        c.power = Range3 {
            cur,
            min: p.get("cap_min").and_then(|v| v.as_f64()).unwrap_or(cur),
            max: p.get("cap_max").and_then(|v| v.as_f64()).unwrap_or(cur),
        };
        c.power_default = p.get("cap_default").and_then(|v| v.as_f64()).unwrap_or(cur);
    }

    if let Some(l) = stats.get("performance_level").and_then(|v| v.as_str()) {
        c.perf_level = l.to_string();
    }

    // Clock ranges come from device_clocks_info (RDNA shape).
    let clk_req = format!(
        "{{\"command\":\"device_clocks_info\",\"args\":{{\"id\":\"{}\"}}}}",
        json_escape(id)
    );
    if let Ok(clk) = lact_call(sock, &clk_req, Duration::from_secs(5)) {
        if let Some(data) = clk.get("table").and_then(|t| t.get("value")).and_then(|v| v.get("data"))
        {
            let od = data.get("od_range");
            let sclk_off = data.get("sclk_offset").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let volt_off = data.get("voltage_offset").and_then(|v| v.as_f64()).unwrap_or(0.0);
            if let Some(od) = od {
                if let Some(v) = od.get("sclk_offset") {
                    c.sclk_offset = range_from(v, sclk_off);
                }
                if let Some(v) = od.get("voltage_offset") {
                    c.volt_offset = range_from(v, volt_off);
                }
            }
            if let Some(cm) = data.get("current_mclk_range") {
                let cur_max = cm.get("max").and_then(|v| v.as_f64()).unwrap_or(0.0);
                let cur_min = cm.get("min").and_then(|v| v.as_f64()).unwrap_or(0.0);
                let (a_min, a_max) = od
                    .and_then(|o| o.get("mclk"))
                    .map(|m| {
                        (
                            m.get("min").and_then(|v| v.as_f64()).unwrap_or(cur_min),
                            m.get("max").and_then(|v| v.as_f64()).unwrap_or(cur_max),
                        )
                    })
                    .unwrap_or((cur_min, cur_max));
                c.mclk_max = Range3 { cur: cur_max, min: cur_min, max: a_max };
                c.mclk_min = Range3 { cur: cur_min, min: a_min, max: a_max };
            }
        }
    }

    if c.fan_curve.is_empty() {
        c.fan_curve = vec![(40, 0.3), (50, 0.35), (60, 0.5), (70, 0.75), (80, 1.0)];
    }
    c
}

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

struct Shared {
    cur: Mutex<Sample>,
    history: Mutex<VecDeque<Sample>>,
    history_cap: usize,
    seq: AtomicU64,
    ctl: Mutex<CtlState>,
    ctl_ms: AtomicI64,
    lact_ok: AtomicBool,
    thermal: Mutex<Thermal>,
    /// overdrive fan-control dir, for handing control back to the firmware.
    fan_ctrl: String,
    state_path: String,
}

impl Shared {
    fn ctl_fresh(&self, sock: &str, id: &str) -> CtlState {
        if now_ms() - self.ctl_ms.load(Ordering::SeqCst) < 5000 {
            return self.ctl.lock().unwrap().clone();
        }
        let c = fetch_ctl(sock, id);
        self.lact_ok.store(c.ok, Ordering::SeqCst);
        *self.ctl.lock().unwrap() = c.clone();
        self.ctl_ms.store(now_ms(), Ordering::SeqCst);
        c
    }
    fn invalidate_ctl(&self) {
        self.ctl_ms.store(0, Ordering::SeqCst);
    }
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
    let _ = s.set_read_timeout(Some(Duration::from_secs(10)));
    let mut buf = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > 64 * 1024 {
            return None;
        }
        match s.read(&mut chunk) {
            Ok(0) => return None,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(_) => return None,
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.lines();
    let request_line = lines.next()?.to_string();
    let mut words = request_line.split_whitespace();
    let method = words.next()?.to_string();
    let path = words.next()?.to_string();
    let mut content_length = 0usize;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            if k.eq_ignore_ascii_case("content-length") {
                content_length = v.trim().parse().unwrap_or(0);
            }
        }
    }
    let mut body = buf[head_end..].to_vec();
    while body.len() < content_length {
        match s.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => body.extend_from_slice(&chunk[..n]),
            Err(_) => break,
        }
    }
    Some(Req {
        method,
        path,
        body: String::from_utf8_lossy(&body).to_string(),
    })
}

fn send_bytes(s: &mut TcpStream, status: &str, ctype: &str, body: &[u8], extra: &str) {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n",
        body.len()
    );
    let _ = s.write_all(head.as_bytes());
    let _ = s.write_all(body);
}

fn send_json(s: &mut TcpStream, status: &str, body: &str) {
    send_bytes(s, status, "application/json", body.as_bytes(), "Cache-Control: no-store\r\n");
}

fn send_text(s: &mut TcpStream, status: &str, body: &str) {
    send_bytes(s, status, "text/plain; charset=utf-8", body.as_bytes(), "");
}

fn downsampled_json(history: &VecDeque<Sample>, max_points: usize) -> String {
    let n = history.len();
    let items: Vec<String> = if n <= max_points {
        history.iter().map(|s| s.to_json()).collect()
    } else {
        let step = n as f64 / max_points as f64;
        (0..max_points)
            .map(|i| history[(i as f64 * step) as usize].to_json())
            .collect()
    };
    format!("[{}]", items.join(","))
}

fn snapshot_json(sh: &Shared, sock: &str, id: &str) -> String {
    let cur = sh.cur.lock().unwrap().clone();
    let hist = sh.history.lock().unwrap();
    let ctl = sh.ctl_fresh(sock, id);
    let thermal = sh.thermal.lock().unwrap().to_json();
    format!(
        "{{\"now\":{},\"current\":{},\"history\":{},\"control\":{},\"thermal\":{}}}",
        now_ms(),
        cur.to_json(),
        downsampled_json(&hist, 600),
        ctl.to_json(),
        thermal
    )
}

fn sse_stream(mut s: TcpStream, sh: Arc<Shared>, _sock: String, _id: String) {
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
            let ev = format!("data: {}\n\n", cur.to_json());
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

fn body_json(body: &str) -> Json {
    parse_json(body).unwrap_or(Json::Null)
}

fn json_field_bool(j: &Json, k: &str) -> Option<bool> {
    j.get(k).and_then(|v| v.as_bool())
}
fn json_field_f64(j: &Json, k: &str) -> Option<f64> {
    j.get(k).and_then(|v| v.as_f64())
}

/// Build and apply a fan-control update via LACT.
fn apply_fan(sh: &Shared, sock: &str, id: &str, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let cur = sh.ctl_fresh(sock, id);
    let enabled = json_field_bool(&j, "enabled").unwrap_or(cur.fan_enabled);
    let mode = j
        .get("mode")
        .and_then(|v| v.as_str())
        .unwrap_or(if cur.fan_mode == "static" { "static" } else { "curve" })
        .to_string();
    let static_speed = json_field_f64(&j, "static_speed").unwrap_or(cur.fan_static).clamp(0.0, 1.0);
    let temp_key = j
        .get("temperature_key")
        .and_then(|v| v.as_str())
        .unwrap_or(&cur.temp_key)
        .to_string();

    // Curve: accept [[temp,speed],...] (frontend) or {"40":0.3,...}.
    let mut curve: Vec<(i32, f64)> = Vec::new();
    if let Some(arr) = j.get("curve").and_then(|v| v.as_arr()) {
        for pair in arr {
            if let Some(p) = pair.as_arr() {
                if let (Some(t), Some(s)) = (
                    p.first().and_then(|v| v.as_f64()),
                    p.get(1).and_then(|v| v.as_f64()),
                ) {
                    curve.push((t as i32, s.clamp(0.0, 1.0)));
                }
            }
        }
    } else if let Some(obj) = j.get("curve") {
        for (k, v) in obj.entries() {
            if let (Ok(t), Some(s)) = (k.parse::<i32>(), v.as_f64()) {
                curve.push((t, s.clamp(0.0, 1.0)));
            }
        }
    }
    if curve.is_empty() {
        curve = cur.fan_curve.clone();
    }
    curve.sort_by_key(|(t, _)| *t);

    let mut pmfw = String::from("{");
    {
        let mut first = true;
        let mut add = |k: &str, v: String| {
            if !first {
                pmfw.push(',');
            }
            first = false;
            pmfw.push_str(&format!("\"{k}\":{v}"));
        };
        if let Some(v) = json_field_f64(&j, "minimum_pwm") {
            add("minimum_pwm", format!("{}", v as u32));
        }
        if let Some(v) = json_field_f64(&j, "target_temperature") {
            add("target_temperature", format!("{}", v as u32));
        }
        if let Some(v) = json_field_f64(&j, "acoustic_target") {
            add("acoustic_target", format!("{}", v as u32));
        }
        if let Some(v) = json_field_f64(&j, "acoustic_limit") {
            add("acoustic_limit", format!("{}", v as u32));
        }
        if let Some(v) = json_field_bool(&j, "zero_rpm") {
            add("zero_rpm", v.to_string());
        }
        if let Some(v) = json_field_f64(&j, "zero_rpm_threshold") {
            add("zero_rpm_threshold", format!("{}", v as u32));
        }
    }
    pmfw.push('}');

    let curve_json = curve
        .iter()
        .map(|(t, s)| format!("\"{t}\":{}", fnum(*s)))
        .collect::<Vec<_>>()
        .join(",");

    let spindown = json_field_f64(&j, "spindown_delay_ms").unwrap_or(0.0) as u64;
    let change = json_field_f64(&j, "change_threshold").unwrap_or(0.0) as u64;

    let req = format!(
        "{{\"command\":\"set_fan_control\",\"args\":{{\"id\":\"{}\",\"enabled\":{},\"mode\":\"{}\",\"static_speed\":{},\"curve\":{{{}}},\"temperature_key\":\"{}\",\"pmfw\":{},\"spindown_delay_ms\":{},\"change_threshold\":{}}}}}",
        json_escape(id),
        enabled,
        mode,
        fnum(static_speed),
        curve_json,
        json_escape(&temp_key),
        pmfw,
        spindown,
        change
    );
    lact_set(sock, &req)?;
    sh.invalidate_ctl();
    Ok(format!("fan updated (enabled={enabled}, mode={mode})"))
}

fn apply_power(sh: &Shared, sock: &str, id: &str, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let cap = json_field_f64(&j, "cap");
    let cap_json = match cap {
        Some(v) => fnum(v),
        None => "null".to_string(),
    };
    let req = format!(
        "{{\"command\":\"set_power_cap\",\"args\":{{\"id\":\"{}\",\"cap\":{cap_json}}}}}",
        json_escape(id)
    );
    lact_set(sock, &req)?;
    sh.invalidate_ctl();
    Ok(format!("power cap set to {cap_json} W"))
}

fn apply_perf(sh: &Shared, sock: &str, id: &str, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let level = j
        .get("level")
        .and_then(|v| v.as_str())
        .ok_or("missing level")?
        .to_string();
    if !matches!(level.as_str(), "auto" | "low" | "high" | "manual") {
        return Err("level must be auto|low|high|manual".into());
    }
    let req = format!(
        "{{\"command\":\"set_performance_level\",\"args\":{{\"id\":\"{}\",\"performance_level\":\"{level}\"}}}}",
        json_escape(id)
    );
    lact_set(sock, &req)?;
    sh.invalidate_ctl();
    Ok(format!("performance level set to {level}"))
}

fn apply_clocks(sh: &Shared, sock: &str, id: &str, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let mut cmds: Vec<String> = Vec::new();
    if json_field_bool(&j, "reset").unwrap_or(false) {
        cmds.push("{\"type\":\"reset\",\"value\":null}".to_string());
    } else {
        let mut push = |ty: String, val: f64| cmds.push(format!("{{\"type\":{ty},\"value\":{}}}", val as i64));
        if let Some(v) = json_field_f64(&j, "gpu_clock_offset") {
            push("{\"gpu_clock_offset\":0}".to_string(), v);
        }
        if let Some(v) = json_field_f64(&j, "voltage_offset") {
            push("\"voltage_offset\"".to_string(), v);
        }
        if let Some(v) = json_field_f64(&j, "min_memory_clock") {
            push("\"min_memory_clock\"".to_string(), v);
        }
        if let Some(v) = json_field_f64(&j, "max_memory_clock") {
            push("\"max_memory_clock\"".to_string(), v);
        }
        if let Some(v) = json_field_f64(&j, "max_core_clock") {
            push("\"max_core_clock\"".to_string(), v);
        }
        if let Some(v) = json_field_f64(&j, "min_core_clock") {
            push("\"min_core_clock\"".to_string(), v);
        }
    }
    if cmds.is_empty() {
        return Err("no clock settings supplied".into());
    }
    let req = format!(
        "{{\"command\":\"batch_set_clocks_value\",\"args\":{{\"id\":\"{}\",\"commands\":[{}]}}}}",
        json_escape(id),
        cmds.join(",")
    );
    lact_set(sock, &req)?;
    sh.invalidate_ctl();
    Ok("clocks updated".to_string())
}

fn apply_thermal(sh: &Shared, sock: &str, id: &str, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let action = j
        .get("action")
        .and_then(|v| v.as_str())
        .unwrap_or("apply")
        .to_string();
    let mut th = sh.thermal.lock().unwrap();

    if action == "stop" {
        th.disarm();
        let r = reset_fan_curve(&sh.fan_ctrl);
        thermal_save(&sh.state_path, &th);
        r?;
        return Ok("PID controller stopped; fan returned to GPU firmware".to_string());
    }

    th.apply_json(&j);
    th.enabled = true;
    th.active = true;
    th.handed_off = false;
    th.reset_loop();
    let (target, source, kp, ki, kd) = (th.target, th.source.clone(), th.kp, th.ki, th.kd);
    thermal_save(&sh.state_path, &th);
    drop(th);

    // Release LACT's own fan control so the two do not fight over the curve.
    let req = format!(
        "{{\"command\":\"set_fan_control\",\"args\":{{\"id\":\"{}\",\"enabled\":false}}}}",
        json_escape(id)
    );
    if let Err(e) = lact_set(sock, &req) {
        log(&format!("warning: could not disable LACT fan control: {e}"));
    }
    sh.invalidate_ctl();
    Ok(format!(
        "PID armed: target {target} °C on {source} temp (kp={kp}, ki={ki}, kd={kd})"
    ))
}

fn handle(mut s: TcpStream, sh: Arc<Shared>, sock: String, id: String) {
    let Some(req) = read_request(&mut s) else {
        return;
    };
    let path = req.path.split('?').next().unwrap_or("/").to_string();

    // ---- static frontend ----
    if req.method == "GET" {
        match path.as_str() {
            "/" | "/index.html" => {
                send_bytes(&mut s, "200 OK", "text/html; charset=utf-8", INDEX_HTML.as_bytes(),
                    "Cache-Control: no-store\r\n");
                return;
            }
            "/app.js" => {
                send_bytes(&mut s, "200 OK", "application/javascript; charset=utf-8", APP_JS.as_bytes(),
                    "Cache-Control: no-store\r\n");
                return;
            }
            "/style.css" => {
                send_bytes(&mut s, "200 OK", "text/css; charset=utf-8", STYLE_CSS.as_bytes(),
                    "Cache-Control: no-store\r\n");
                return;
            }
            "/favicon.svg" => {
                send_bytes(&mut s, "200 OK", "image/svg+xml", FAVICON.as_bytes(),
                    "Cache-Control: max-age=86400\r\n");
                return;
            }
            "/api/snapshot" => {
                let body = snapshot_json(&sh, &sock, &id);
                send_json(&mut s, "200 OK", &body);
                return;
            }
            "/api/control" => {
                let c = sh.ctl_fresh(&sock, &id);
                send_json(&mut s, "200 OK", &c.to_json());
                return;
            }
            "/api/thermal" => {
                let t = sh.thermal.lock().unwrap().to_json();
                send_json(&mut s, "200 OK", &t);
                return;
            }
            "/api/stream" => {
                sse_stream(s, sh, sock, id);
                return;
            }
            "/api/health" => {
                let ok = sh.lact_ok.load(Ordering::SeqCst);
                send_json(&mut s, "200 OK", &format!("{{\"ok\":true,\"lact\":{ok}}}"));
                return;
            }
            _ => {
                send_text(&mut s, "404 Not Found", "not found");
                return;
            }
        }
    }

    if req.method != "POST" {
        send_text(&mut s, "405 Method Not Allowed", "method not allowed");
        return;
    }

    let result = match path.as_str() {
        "/api/fan" => apply_fan(&sh, &sock, &id, &req.body),
        "/api/power" => apply_power(&sh, &sock, &id, &req.body),
        "/api/perf" => apply_perf(&sh, &sock, &id, &req.body),
        "/api/clocks" => apply_clocks(&sh, &sock, &id, &req.body),
        "/api/thermal" => apply_thermal(&sh, &sock, &id, &req.body),
        "/api/confirm" => lact_confirm(&sock, true)
            .map(|_| "confirmed".to_string())
            .map_err(|e| e),
        "/api/revert" => {
            let r = lact_confirm(&sock, false);
            sh.invalidate_ctl();
            r.map(|_| "reverted".to_string())
        }
        _ => {
            send_text(&mut s, "404 Not Found", "not found");
            return;
        }
    };

    match result {
        Ok(msg) => {
            log(&format!("{path}: {msg}"));
            send_json(&mut s, "200 OK", &format!("{{\"ok\":true,\"message\":\"{}\",\"control\":{}}}",
                json_escape(&msg), sh.ctl_fresh(&sock, &id).to_json()));
        }
        Err(e) => {
            log(&format!("{path} failed: {e}"));
            send_json(&mut s, "400 Bad Request", &format!("{{\"ok\":false,\"error\":\"{}\"}}",
                json_escape(&e)));
        }
    }
}

// ---------------------------------------------------------------------------
// Embedded frontend
// ---------------------------------------------------------------------------

const INDEX_HTML: &str = include_str!("index.html");
const APP_JS: &str = include_str!("app.js");
const STYLE_CSS: &str = include_str!("style.css");
const FAVICON: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="6" fill="#12161f"/><path d="M8 20l4-9 4 6 3-4 5 7z" fill="#4ade80"/><circle cx="10" cy="9" r="2" fill="#38bdf8"/></svg>"##;

// ---------------------------------------------------------------------------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut listen = "127.0.0.1:8087".to_string();
    let mut pci = "0000:03:00.0".to_string();
    let mut lact_sock = "/run/lactd.sock".to_string();
    let mut interval_ms: u64 = 500;
    let mut history_secs: u64 = 1800;
    let mut state_path = "/var/lib/gpu-panel/thermal.json".to_string();

    let mut i = 1;
    while i < args.len() {
        let need = |i: usize| -> String {
            args.get(i + 1).cloned().unwrap_or_else(|| {
                eprintln!("missing value for {}", args[i]);
                std::process::exit(2);
            })
        };
        match args[i].as_str() {
            "--listen" => listen = need(i),
            "--pci" => pci = need(i),
            "--lact-sock" => lact_sock = need(i),
            "--interval-ms" => interval_ms = need(i).parse().unwrap_or(500),
            "--history-secs" => history_secs = need(i).parse().unwrap_or(1800),
            "--state" => state_path = need(i),
            "-h" | "--help" => {
                println!("gpu-panel [--listen ADDR] [--pci BDF] [--lact-sock PATH] [--interval-ms N] [--history-secs N] [--state PATH]");
                return;
            }
            other => {
                eprintln!("unknown option: {other}");
                std::process::exit(2);
            }
        }
        i += 2;
    }

    let paths = match resolve_paths(&pci) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("failed to resolve GPU {pci}: {e}");
            std::process::exit(1);
        }
    };
    log(&format!("GPU {pci}: dev={} hwmon={}", paths.dev, paths.hwmon));
    for (label, _) in &paths.temps {
        log(&format!("  temperature sensor: {label}"));
    }

    let gpu_id = match lact_call(
        &lact_sock,
        "{\"command\":\"list_devices\"}",
        Duration::from_secs(5),
    ) {
        Ok(Json::Arr(devs)) => devs
            .iter()
            .find(|d| {
                d.get("id")
                    .and_then(|v| v.as_str())
                    .map(|s| {
                        let want = format!("{}", pci.trim_start_matches("0000:"));
                        s.ends_with(&want)
                    })
                    .unwrap_or(false)
            })
            .or_else(|| devs.first())
            .and_then(|d| d.get("id").and_then(|v| v.as_str()).map(String::from))
            .unwrap_or_else(|| format!("1002:7551-1458:242F-{pci}")),
        _ => {
            log("warning: could not list GPU ids from LACT; using PCI-derived id");
            format!("1002:7551-1458:242F-{pci}")
        }
    };
    log(&format!("LACT device id: {gpu_id}"));

    let history_cap = ((history_secs * 1000) / interval_ms.max(1)) as usize;
    let thermal = thermal_load(&state_path).unwrap_or_default();
    if thermal.enabled {
        log("restoring armed PID thermal controller from saved state");
    }

    let handler = on_signal as *const () as usize;
    unsafe {
        signal(SIGTERM, handler);
        signal(SIGINT, handler);
    }

    let first = take_sample(&paths);
    let sh = Arc::new(Shared {
        cur: Mutex::new(first),
        history: Mutex::new(VecDeque::with_capacity(history_cap.min(1 << 16))),
        history_cap: history_cap.max(60),
        seq: AtomicU64::new(0),
        ctl: Mutex::new(CtlState::default()),
        ctl_ms: AtomicI64::new(0),
        lact_ok: AtomicBool::new(false),
        thermal: Mutex::new(thermal),
        fan_ctrl: paths.fan_ctrl.clone(),
        state_path: state_path.clone(),
    });

    // Sampler thread.
    {
        let sh = sh.clone();
        let sp = paths.clone();
        thread::Builder::new()
            .name("sampler".into())
            .spawn(move || loop {
                let mut s = take_sample(&sp);
                {
                    let th = sh.thermal.lock().unwrap();
                    if th.active {
                        s.fan_cmd = th.duty.round() as i32;
                        s.ctrl_temp = th.measured;
                        s.target = th.target;
                    }
                }
                *sh.cur.lock().unwrap() = s.clone();
                {
                    let mut h = sh.history.lock().unwrap();
                    h.push_back(s);
                    while h.len() > sh.history_cap {
                        h.pop_front();
                    }
                }
                sh.seq.fetch_add(1, Ordering::SeqCst);
                thread::sleep(Duration::from_millis(interval_ms.max(100)));
            })
            .expect("spawn sampler");
    }

    // Thermal PID controller: when armed it owns the GPU fan (LACT fan control
    // has been disabled) and writes a fresh overdrive curve every interval.
    {
        let sh = sh.clone();
        let paths = paths.clone();
        let sock = lact_sock.clone();
        let id = gpu_id.clone();
        thread::Builder::new()
            .name("thermal".into())
            .spawn(move || loop {
                if SHUTDOWN.load(Ordering::SeqCst) {
                    let was_active = {
                        let mut th = sh.thermal.lock().unwrap();
                        let a = th.active || th.enabled;
                        th.disarm();
                        a
                    };
                    if was_active {
                        let _ = reset_fan_curve(&paths.fan_ctrl);
                        log("shutdown: fan control returned to GPU firmware");
                    }
                    std::process::exit(0);
                }

                let (enabled, active, handed_off, interval, source) = {
                    let th = sh.thermal.lock().unwrap();
                    (
                        th.enabled,
                        th.active,
                        th.handed_off,
                        th.interval_ms,
                        th.source.clone(),
                    )
                };
                if !enabled || !active {
                    thread::sleep(Duration::from_millis(500));
                    continue;
                }
                if !handed_off {
                    let req = format!(
                        "{{\"command\":\"set_fan_control\",\"args\":{{\"id\":\"{}\",\"enabled\":false}}}}",
                        json_escape(&id)
                    );
                    if let Err(e) = lact_set(&sock, &req) {
                        log(&format!("warning: LACT fan handoff failed: {e}"));
                    }
                    sh.thermal.lock().unwrap().handed_off = true;
                    sh.invalidate_ctl();
                }

                let temp = fan_source_temp(&paths, &source);
                // Firmware curve x-axis is hotspot; shift the centre so the
                // ramp lines up with the regulated sensor. Cap the shift so the
                // centre anchor stays representable (<=100 C) and the PID duty is
                // exactly delivered at hotspot == centre.
                let hotspot = temp_by_label(&paths, "junction");
                let now = now_ms();
                let (curve, duty, center, changed) = {
                    let mut th = sh.thermal.lock().unwrap();
                    let duty = th.step(temp, hotspot, now);
                    th.last_update_ms = now;
                    let offset = (hotspot - temp).clamp(0.0, (100.0 - th.target).max(0.0));
                    th.center = th.target + offset;
                    // Only touch the firmware when the command actually moves;
                    // a 1 Hz rewrite of an unchanged curve is pointless churn.
                    let changed = th.last_write_duty < 0.0
                        || (duty - th.last_write_duty).abs() >= 1.0
                        || (th.center - th.last_write_center).abs() >= 0.5;
                    (
                        build_pid_curve(th.center, duty, th.duty_min),
                        duty,
                        th.center,
                        changed,
                    )
                };
                if changed {
                    match write_fan_curve(&paths.fan_ctrl, &curve) {
                        Ok(_) => {
                            let mut th = sh.thermal.lock().unwrap();
                            th.writes += 1;
                            th.last_write_duty = duty;
                            th.last_write_center = center;
                            th.last_error.clear();
                        }
                        Err(e) => {
                            let mut th = sh.thermal.lock().unwrap();
                            th.last_error = e.clone();
                            log(&format!("fan curve write failed: {e}"));
                        }
                    }
                }
                thread::sleep(Duration::from_millis(interval.clamp(250, 10_000)));
            })
            .expect("spawn thermal controller");
    }

    // Warm the control state (and keep it fresh so the UI has ranges ready).
    {
        let sh = sh.clone();
        let sock = lact_sock.clone();
        let id = gpu_id.clone();
        thread::Builder::new()
            .name("ctl".into())
            .spawn(move || loop {
                let c = fetch_ctl(&sock, &id);
                sh.lact_ok.store(c.ok, Ordering::SeqCst);
                *sh.ctl.lock().unwrap() = c;
                sh.ctl_ms.store(now_ms(), Ordering::SeqCst);
                thread::sleep(Duration::from_secs(15));
            })
            .expect("spawn ctl refresher");
    }

    let listener = match TcpListener::bind(&listen) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("failed to bind {listen}: {e}");
            std::process::exit(1);
        }
    };
    log(&format!("listening on http://{listen}"));

    for stream in listener.incoming() {
        let Ok(s) = stream else { continue };
        let (sh2, sock2, id2) = (sh.clone(), lact_sock.clone(), gpu_id.clone());
        thread::Builder::new()
            .name("conn".into())
            .spawn(move || handle(s, sh2, sock2, id2))
            .ok();
    }
}
