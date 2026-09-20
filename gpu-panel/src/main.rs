//! gpu-panel — GPU telemetry + control web panel for zen3-nixos.
//!
//! Reads *all* monitoring data natively from sysfs (temps, fan, power,
//! clocks, utilisation, VRAM) and keeps a rolling history in memory.
//! Serves a live web dashboard (embedded HTML/JS/CSS, canvas charts, SSE
//! stream) plus JSON control endpoints.
//!
//! Writes (fan curve / power cap / clocks / voltage / performance level) go
//! straight to the amdgpu overdrive sysfs interfaces; there is no intermediary
//! daemon. Exactly one writer owns the fan at a time -- the fan thread applies
//! either the PID curve or the configured curve -- and the panel hands it back
//! to the firmware on shutdown.
//!
//! Zero dependencies: Rust std only.

use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
    fn is_null(&self) -> bool {
        matches!(self, Json::Null)
    }
    fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
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
    /// `pp_od_clk_voltage`: clock/voltage overdrive table.
    od_clk_voltage: String,
    /// `power_dpm_force_performance_level`.
    perf_level: String,
    /// hwmon power cap, in microwatts.
    power_cap: String,
    /// hwmon default power cap, in microwatts.
    power_cap_default: String,
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
    let od_clk_voltage = format!("{dev}/pp_od_clk_voltage");
    let od_clk_voltage = if std::path::Path::new(&od_clk_voltage).exists() {
        od_clk_voltage
    } else {
        String::new()
    };
    Ok(Paths {
        dev: dev.clone(),
        hwmon: hwmon.clone(),
        temps,
        vddgfx,
        fan_ctrl,
        od_clk_voltage,
        perf_level: format!("{dev}/power_dpm_force_performance_level"),
        power_cap: format!("{hwmon}/power1_cap"),
        power_cap_default: format!("{hwmon}/power1_cap_default"),
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
/// Speeds arrive as fractions (0..1); the SMU wants whole percent, and it
/// rejects anything below the 25% floor, so the conversion happens here.
fn write_fan_curve(ctrl: &str, points: &[(i32, f64)]) -> Result<(), String> {
    if ctrl.is_empty() {
        return Err("no overdrive fan-control interface on this GPU".into());
    }
    let f = format!("{ctrl}/fan_curve");
    for (i, (t, s)) in points.iter().enumerate() {
        let pct = (s * 100.0).round().clamp(25.0, 100.0) as i64;
        write_file_retry(&f, &format!("{i} {t} {pct}\n"))?;
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
/// Curve for a PID duty `duty` (percent) with the anchor at `center_hotspot`.
/// Returns speeds as **fractions** (0..1), like the rest of the panel; only
/// `write_fan_curve` converts to the whole percent the SMU wants.
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
        .map(|(t, s)| (t, s / 100.0))
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
    last_meas: Option<f64>,
    last_t_ms: i64,
    last_update_ms: i64,
    writes: u64,
    last_error: String,
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
            last_meas: None,
            last_t_ms: 0,
            last_update_ms: 0,
            writes: 0,
            last_error: String::new(),
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
    }

    fn disarm(&mut self) {
        self.enabled = false;
        self.active = false;
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

/// Persist the whole panel state: the PID configuration plus every hardware
/// setting the panel owns. One file, one writer.
fn state_save(path: &str, t: &Thermal, s: &Settings) {
    let body = format!(
        "{{\"enabled\":{},\"target\":{},\"source\":\"{}\",\"kp\":{},\"ki\":{},\"kd\":{},\"duty_min\":{},\"duty_max\":{},\"interval_ms\":{},{}}}",
        t.enabled,
        fnum(t.target),
        json_escape(&t.source),
        fnum(t.kp),
        fnum(t.ki),
        fnum(t.kd),
        fnum(t.duty_min),
        fnum(t.duty_max),
        t.interval_ms,
        settings_to_json(s)
    );
    if let Some(dir) = std::path::Path::new(path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Err(e) = std::fs::write(path, body) {
        log(&format!("could not save state to {path}: {e}"));
    }
}

fn state_load(path: &str) -> Option<(Thermal, Settings)> {
    let text = std::fs::read_to_string(path).ok()?;
    let j = parse_json(&text)?;
    let mut t = Thermal::default();
    t.apply_json(&j);
    t.enabled = j.get("enabled").and_then(|v| v.as_bool()).unwrap_or(false);
    // `active` is runtime state and is not part of the saved config, so it has
    // to be re-armed here. Without this the fan thread's
    // `if !armed { ... }` branch runs forever after every restart: the panel
    // reports the loop as armed, `/api/thermal` keeps
    // `enabled: true, active: false, writes: 0`, and the fan stays on the
    // firmware default.
    t.active = t.enabled;
    Some((t, settings_from_json(&j)))
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
// Direct sysfs control
// ---------------------------------------------------------------------------
//
// The panel is the only writer of the overdrive interfaces; there is no
// intermediary daemon. Every knob below was verified against this GPU
// (R9700, SMU 14, kernel 7.2):
//
//   fan curve      gpu_od/fan_ctrl/fan_curve             "<i> <tempC> <speed%>" x5, "c", "r"
//   fan limits     gpu_od/fan_ctrl/fan_minimum_pwm        int %
//                  gpu_od/fan_ctrl/fan_target_temperature
//                  gpu_od/fan_ctrl/acoustic_{target,limit}_rpm_threshold
//                  gpu_od/fan_ctrl/fan_zero_rpm_enable
//   power cap      hwmon/power1_cap                       microwatts
//   perf level     power_dpm_force_performance_level      auto|low|high|manual
//   sclk offset    pp_od_clk_voltage                      "s <mhz>"
//   vddgfx offset  pp_od_clk_voltage                      "vo <mv>"
//   vram clocks    pp_od_clk_voltage                      "m 0 <mhz>" / "m 1 <mhz>"
//   commit/reset   pp_od_clk_voltage                      "c" / "r"

/// Fan curve / static-speed configuration, applied by the fan thread whenever
/// the PID controller is not armed.
#[derive(Clone)]
struct FanCfg {
    enabled: bool,
    /// "curve" or "static"
    mode: String,
    /// 0..1, used when `mode == "static"`.
    static_speed: f64,
    /// "edge" | "junction" | "mem"
    temperature_key: String,
    /// Five (temperature C, speed 0..1) anchors.
    curve: Vec<(i32, f64)>,
}

impl Default for FanCfg {
    fn default() -> Self {
        FanCfg {
            enabled: false,
            mode: "static".into(),
            static_speed: 1.0,
            temperature_key: "edge".into(),
            curve: vec![(40, 0.3), (50, 0.35), (60, 0.5), (70, 0.75), (80, 1.0)],
        }
    }
}

/// Clock/voltage overdrive overrides. `Settings::clocks == None` means "never
/// configured", in which case the OD table is left exactly as the firmware
/// left it.
#[derive(Clone, Default)]
struct Clocks {
    gpu_clock_offset: f64,
    voltage_offset: f64,
    min_memory_clock: f64,
    max_memory_clock: f64,
}

/// Everything the panel persists besides the PID runtime state.
#[derive(Clone)]
struct Settings {
    fan: FanCfg,
    /// Watts; `None` restores `power1_cap_default`.
    power_cap: Option<f64>,
    perf_level: String,
    clocks: Option<Clocks>,
    /// Set when a clock/voltage change is applied and cleared by a clean exit.
    /// If it is still set at startup the previous session went down without
    /// exiting, so the change is a prime suspect for the crash: it gets
    /// reverted instead of re-applied. Without this, an unstable undervolt
    /// would be restored on every boot and the machine would never come up.
    clocks_pending: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            fan: FanCfg::default(),
            power_cap: None,
            perf_level: "auto".into(),
            clocks: None,
            clocks_pending: false,
        }
    }
}

fn settings_to_json(s: &Settings) -> String {
    let curve = s
        .fan
        .curve
        .iter()
        .map(|(t, v)| format!("[{t},{}]", fnum(*v)))
        .collect::<Vec<_>>()
        .join(",");
    let clocks = match &s.clocks {
        Some(c) => format!(
            "{{\"gpu_clock_offset\":{},\"voltage_offset\":{},\"min_memory_clock\":{},\"max_memory_clock\":{}}}",
            fnum(c.gpu_clock_offset),
            fnum(c.voltage_offset),
            fnum(c.min_memory_clock),
            fnum(c.max_memory_clock)
        ),
        None => "null".to_string(),
    };
    let cap = match s.power_cap {
        Some(v) => fnum(v),
        None => "null".to_string(),
    };
    format!(
        "\"fan\":{{\"enabled\":{},\"mode\":\"{}\",\"static_speed\":{},\"temperature_key\":\"{}\",\"curve\":[{}]}},\"power_cap\":{},\"perf_level\":\"{}\",\"clocks\":{},\"clocks_pending\":{}",
        s.fan.enabled,
        json_escape(&s.fan.mode),
        fnum(s.fan.static_speed),
        json_escape(&s.fan.temperature_key),
        curve,
        cap,
        json_escape(&s.perf_level),
        clocks,
        s.clocks_pending
    )
}

fn settings_from_json(j: &Json) -> Settings {
    let mut s = Settings::default();
    if let Some(f) = j.get("fan").filter(|v| !v.is_null()) {
        if let Some(v) = f.get("enabled").and_then(|v| v.as_bool()) {
            s.fan.enabled = v;
        }
        if let Some(v) = f.get("mode").and_then(|v| v.as_str()) {
            if v == "static" || v == "curve" {
                s.fan.mode = v.to_string();
            }
        }
        if let Some(v) = f.get("static_speed").and_then(|v| v.as_f64()) {
            s.fan.static_speed = v.clamp(0.0, 1.0);
        }
        if let Some(v) = f.get("temperature_key").and_then(|v| v.as_str()) {
            if matches!(v, "edge" | "junction" | "mem") {
                s.fan.temperature_key = v.to_string();
            }
        }
        if let Some(arr) = f.get("curve").and_then(|v| v.as_arr()) {
            let pts: Vec<(f64, f64)> = arr
                .iter()
                .filter_map(|p| {
                    let p = p.as_arr()?;
                    Some((p.first()?.as_f64()?, p.get(1)?.as_f64()?))
                })
                .collect();
            if !pts.is_empty() {
                s.fan.curve = normalize_curve(&pts);
            }
        }
    }
    s.power_cap = j.get("power_cap").and_then(|v| v.as_f64());
    if let Some(v) = j.get("perf_level").and_then(|v| v.as_str()) {
        s.perf_level = v.to_string();
    }
    // `clocks: null` means "no overrides"; it must not turn into a Clocks of
    // zeros, which `push_clocks` would then write to the OD table (clamping an
    // zeroed VRAM range onto the table's minimum collapses it to 97 MHz).
    if let Some(c) = j.get("clocks").filter(|v| !v.is_null()) {
        let g = |k: &str| c.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0);
        s.clocks = Some(Clocks {
            gpu_clock_offset: g("gpu_clock_offset"),
            voltage_offset: g("voltage_offset"),
            min_memory_clock: g("min_memory_clock"),
            max_memory_clock: g("max_memory_clock"),
        });
    }
    s.clocks_pending = j
        .get("clocks_pending")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    s
}

/// All numbers in `s`, in order. Handles "25C 100C", "-500Mhz  1000Mhz",
/// "-50mV" and "25 %".
fn parse_nums(s: &str) -> Vec<f64> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for ch in s.chars() {
        if ch.is_ascii_digit() || matches!(ch, '-' | '+' | '.') {
            cur.push(ch);
        } else if !cur.is_empty() {
            if let Ok(v) = cur.parse::<f64>() {
                out.push(v);
            }
            cur.clear();
        }
    }
    if !cur.is_empty() {
        if let Ok(v) = cur.parse::<f64>() {
            out.push(v);
        }
    }
    out
}

/// Parse the current value and `OD_RANGE:` pair out of one of the
/// `gpu_od/fan_ctrl/*` blocks, which share the shape
/// `<HEADER>:\n<value>\nOD_RANGE:\n<KEY>: <min> <max>`.
fn read_od_block(path: &str, key: &str) -> Option<(f64, f64, f64)> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut cur: Option<f64> = None;
    let mut min: Option<f64> = None;
    let mut max: Option<f64> = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.ends_with(':') {
            continue;
        }
        match line.split_once(':') {
            Some((k, v)) if k.trim() == key => {
                let n = parse_nums(v);
                if n.len() >= 2 {
                    min = Some(n[0]);
                    max = Some(n[1]);
                }
            }
            Some(_) => {}
            None => {
                if cur.is_none() {
                    cur = parse_nums(line).first().copied();
                }
            }
        }
    }
    Some((cur.unwrap_or(0.0), min?, max?))
}

/// Parsed `pp_od_clk_voltage`.
#[derive(Clone, Default)]
struct OdTable {
    sclk_offset: f64,
    volt_offset: f64,
    mclk_min: f64,
    mclk_max: f64,
    sclk_range: (f64, f64),
    volt_range: (f64, f64),
    mclk_range: (f64, f64),
}

fn read_od_table(path: &str) -> Option<OdTable> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut t = OdTable::default();
    let mut section = String::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_suffix(':') {
            section = rest.trim().to_string();
            continue;
        }
        if section == "OD_RANGE" {
            if let Some((k, v)) = line.split_once(':') {
                let n = parse_nums(v);
                if n.len() >= 2 {
                    match k.trim() {
                        "SCLK_OFFSET" => t.sclk_range = (n[0], n[1]),
                        "VDDGFX_OFFSET" => t.volt_range = (n[0], n[1]),
                        "MCLK" => t.mclk_range = (n[0], n[1]),
                        _ => {}
                    }
                }
            }
            continue;
        }
        match section.as_str() {
            "OD_SCLK_OFFSET" => t.sclk_offset = parse_nums(line).first().copied().unwrap_or(0.0),
            "OD_VDDGFX_OFFSET" => {
                t.volt_offset = parse_nums(line).first().copied().unwrap_or(0.0)
            }
            "OD_MCLK" => {
                if let Some((idx, v)) = line.split_once(':') {
                    let v = parse_nums(v).first().copied().unwrap_or(0.0);
                    match idx.trim() {
                        "0" => t.mclk_min = v,
                        "1" => t.mclk_max = v,
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    Some(t)
}

/// Normalise a user curve to the five strictly-increasing anchors the SMU
/// accepts, resampling when the point count differs.
fn normalize_curve(points: &[(f64, f64)]) -> Vec<(i32, f64)> {
    let mut pts: Vec<(f64, f64)> = points
        .iter()
        .filter(|(t, _)| t.is_finite())
        .map(|(t, s)| (t.clamp(25.0, 100.0), s.clamp(0.0, 1.0)))
        .collect();
    pts.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    if pts.is_empty() {
        return FanCfg::default().curve;
    }
    if pts.len() == 1 {
        pts.push(pts[0]);
    }
    let lo = pts[0].0;
    let hi = pts[pts.len() - 1].0;
    let sample = |t: f64| -> f64 {
        if t <= pts[0].0 {
            return pts[0].1;
        }
        if t >= hi {
            return pts[pts.len() - 1].1;
        }
        for w in pts.windows(2) {
            if t >= w[0].0 && t <= w[1].0 {
                let span = (w[1].0 - w[0].0).max(1e-9);
                return w[0].1 + (t - w[0].0) / span * (w[1].1 - w[0].1);
            }
        }
        pts[pts.len() - 1].1
    };
    let mut temps: Vec<i32> = Vec::with_capacity(5);
    for i in 0..5 {
        let mut v = (lo + (hi - lo) * (i as f64 / 4.0)).round() as i32;
        if let Some(prev) = temps.last() {
            if v <= *prev {
                v = *prev + 1;
            }
        }
        temps.push(v.min(100));
    }
    let mut speeds: Vec<f64> = temps.iter().map(|t| sample(*t as f64)).collect();
    let mut prev = 0.0;
    for s in speeds.iter_mut() {
        *s = s.clamp(0.0, 1.0).max(prev);
        prev = *s;
    }
    temps.into_iter().zip(speeds).collect()
}

/// The curve to hand the SMU for a fan configuration, as **fractions** (0..1),
/// matching the UI and `normalize_curve`. Static mode is a flat curve at
/// `static_speed` (the anchors still have to be monotonic).
fn fan_curve_for(cfg: &FanCfg) -> Vec<(i32, f64)> {
    if cfg.mode == "static" {
        let sp = cfg.static_speed.clamp(0.0, 1.0);
        return vec![(40, sp), (60, sp), (80, sp), (95, sp), (100, sp)];
    }
    normalize_curve(&cfg.curve.iter().map(|(t, s)| (*t as f64, *s)).collect::<Vec<_>>())
}

/// One write to `pp_od_clk_voltage`. Each command is its own write; a spelling
/// the kernel does not know is rejected with EINVAL.
fn write_od(path: &str, cmd: &str) -> Result<(), String> {
    if path.is_empty() {
        return Err("this GPU has no pp_od_clk_voltage interface".into());
    }
    write_file_retry(path, &format!("{cmd}\n"))
}

/// SMU 14 (RDNA4) spells the offset entries without an index (`s <off>`,
/// `vo <mv>`); older SMUs index them (`s 1 <off>`, `vc 0 <mv>`). Try the plain
/// form first and fall back, so the panel is not tied to one generation.
fn write_od_probe(path: &str, plain: String, indexed: String) -> Result<(), String> {
    match write_od(path, &plain) {
        Ok(()) => Ok(()),
        Err(_) => write_od(path, &indexed),
    }
}

/// Push the clock/voltage overrides, then commit the OD table.
fn push_clocks(p: &Paths, c: &Clocks) -> Result<(), String> {
    if p.od_clk_voltage.is_empty() {
        return Err("this GPU has no pp_od_clk_voltage interface".into());
    }
    let od = p.od_clk_voltage.as_str();
    // Clamp to the ranges the kernel advertises first. An out-of-range value is
    // rejected with EINVAL partway through this write sequence, which would
    // leave a half-applied table pending.
    let t = read_od_table(od).unwrap_or_default();
    let clamp = |v: f64, r: (f64, f64)| {
        if r.1 > r.0 {
            v.clamp(r.0, r.1)
        } else {
            v
        }
    };
    let sclk = clamp(c.gpu_clock_offset, t.sclk_range).round() as i64;
    let volt = clamp(c.voltage_offset, t.volt_range).round() as i64;
    // A memory clock of 0 means "not configured": keep what the table holds.
    // Clamping 0 up to the table minimum instead would collapse the VRAM range
    // (97-1259 MHz -> 97-97 MHz) and silently cripple the card.
    let mut lo = if c.min_memory_clock <= 0.0 {
        t.mclk_min.round() as i64
    } else {
        clamp(c.min_memory_clock, t.mclk_range).round() as i64
    };
    let mut hi = if c.max_memory_clock <= 0.0 {
        t.mclk_max.round() as i64
    } else {
        clamp(c.max_memory_clock, t.mclk_range).round() as i64
    };
    if lo > hi {
        std::mem::swap(&mut lo, &mut hi);
    }
    write_od_probe(od, format!("s {sclk}"), format!("s 1 {sclk}"))?;
    write_od_probe(od, format!("vo {volt}"), format!("vc 0 {volt}"))?;
    write_od(od, &format!("m 0 {lo}"))?;
    write_od(od, &format!("m 1 {hi}"))?;
    write_od(od, "c")
}

fn reset_clocks(p: &Paths) -> Result<(), String> {
    write_od(&p.od_clk_voltage, "r")
}

fn set_power_cap(p: &Paths, watts: f64) -> Result<(), String> {
    let uw = 1_000_000.0;
    let min = read_f64(&format!("{}/power1_cap_min", p.hwmon)).unwrap_or(0.0) / uw;
    let max = read_f64(&format!("{}/power1_cap_max", p.hwmon)).unwrap_or(0.0) / uw;
    let w = if max > min { watts.clamp(min, max) } else { watts };
    write_file_retry(&p.power_cap, &format!("{}\n", (w * uw).round() as i64))
}

fn set_perf_level(p: &Paths, level: &str) -> Result<(), String> {
    if !matches!(level, "auto" | "low" | "high" | "manual") {
        return Err("level must be auto|low|high|manual".into());
    }
    write_file_retry(&p.perf_level, &format!("{level}\n"))
}

/// Curves are compared at ~1% speed resolution for change detection; rewriting
/// an unchanged curve at 1 Hz would be pointless SMU churn.
fn curve_eq(a: &[(i32, f64)], b: &[(i32, f64)]) -> bool {
    a.len() == b.len()
        && a.iter()
            .zip(b.iter())
            .all(|((ta, sa), (tb, sb))| ta == tb && (sa - sb).abs() < 1.0)
}

// ---------------------------------------------------------------------------
// Control state (ranges + current settings), read from sysfs
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

/// Current control state + ranges, read straight from sysfs. Called per
/// request -- this is a handful of small sysfs reads, so there is no cache to
/// invalidate and no daemon to poll.
fn read_ctl(p: &Paths, s: &Settings) -> CtlState {
    let mut c = CtlState::default();
    c.fan_enabled = s.fan.enabled;
    c.fan_mode = s.fan.mode.clone();
    c.fan_static = s.fan.static_speed;
    c.temp_key = s.fan.temperature_key.clone();
    c.fan_curve = fan_curve_for(&s.fan);
    c.temp_min = 25;
    c.temp_max = 100;
    c.perf_level = s.perf_level.clone();
    c.ok = true;

    if p.fan_ctrl.is_empty() {
        c.ok = false;
        c.error = "no gpu_od/fan_ctrl (is amdgpu.ppfeaturemask set?)".into();
    } else {
        let fc = format!("{}/fan_curve", p.fan_ctrl);
        if let Some((_, mn, mx)) = read_od_block(&fc, "FAN_CURVE(hotspot temp)") {
            c.temp_min = mn as i32;
            c.temp_max = mx as i32;
        }
        let block = |name: &str, key: &str| -> PmfwRange {
            match read_od_block(&format!("{}/{}", p.fan_ctrl, name), key) {
                Some((cur, min, max)) => PmfwRange { cur, min, max },
                None => PmfwRange::default(),
            }
        };
        c.minimum_pwm = block("fan_minimum_pwm", "MINIMUM_PWM");
        c.target_temperature = block("fan_target_temperature", "TARGET_TEMPERATURE");
        c.acoustic_target = block("acoustic_target_rpm_threshold", "ACOUSTIC_TARGET");
        c.acoustic_limit = block("acoustic_limit_rpm_threshold", "ACOUSTIC_LIMIT");
        // hwmon raw pwm range, for the curve editor's speed axis.
        c.pwm_max = read_f64(&format!("{}/pwm1_max", p.hwmon)).unwrap_or(255.0);
        c.pwm_min = c.pwm_max * c.minimum_pwm.cur / 100.0;
    }

    let uw = |v: f64| v / 1_000_000.0;
    let cap = read_f64(&p.power_cap).unwrap_or(0.0);
    c.power = Range3 {
        cur: uw(cap),
        min: uw(read_f64(&format!("{}/power1_cap_min", p.hwmon)).unwrap_or(cap)),
        max: uw(read_f64(&format!("{}/power1_cap_max", p.hwmon)).unwrap_or(cap)),
    };
    c.power_default = uw(read_f64(&p.power_cap_default).unwrap_or(cap));

    if let Some(v) = read_trim(&p.perf_level) {
        c.perf_level = v;
    }

    if let Some(od) = read_od_table(&p.od_clk_voltage) {
        c.sclk_offset = Range3 {
            cur: od.sclk_offset,
            min: od.sclk_range.0,
            max: od.sclk_range.1,
        };
        c.volt_offset = Range3 {
            cur: od.volt_offset,
            min: od.volt_range.0,
            max: od.volt_range.1,
        };
        c.mclk_min = Range3 {
            cur: od.mclk_min,
            min: od.mclk_range.0,
            max: od.mclk_range.1,
        };
        c.mclk_max = Range3 {
            cur: od.mclk_max,
            min: od.mclk_range.0,
            max: od.mclk_range.1,
        };
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
    thermal: Mutex<Thermal>,
    settings: Mutex<Settings>,
    /// Last curve handed to the SMU, so the fan thread only writes on change.
    last_curve: Mutex<Vec<(i32, f64)>>,
    paths: Paths,
    state_path: String,
}

impl Shared {
    /// Control state straight from sysfs -- no cache, no daemon to poll.
    fn ctl(&self) -> CtlState {
        read_ctl(&self.paths, &self.settings.lock().unwrap())
    }

    /// Write the persisted state. Must not be called while holding either the
    /// `thermal` or `settings` lock: both guards are taken and released one at
    /// a time, so the two locks are never nested and cannot deadlock.
    fn save(&self) {
        let t = {
            self.thermal.lock().unwrap().clone()
        };
        let s = {
            self.settings.lock().unwrap().clone()
        };
        state_save(&self.state_path, &t, &s);
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

fn snapshot_json(sh: &Shared) -> String {
    let cur = sh.cur.lock().unwrap().clone();
    let hist = sh.history.lock().unwrap();
    let ctl = sh.ctl();
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

/// Apply the fan configuration. The PMFW limits are written straight away;
/// the curve itself is written by the fan thread on its next tick, which keeps
/// the "who owns the fan" decision in exactly one place.
fn apply_fan(sh: &Shared, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let p = &sh.paths;
    if p.fan_ctrl.is_empty() {
        return Err("no gpu_od/fan_ctrl (is amdgpu.ppfeaturemask set?)".into());
    }

    let (mode, enabled) = {
        let mut s = sh.settings.lock().unwrap();
        let mut fan = s.fan.clone();

        if let Some(v) = json_field_bool(&j, "enabled") {
            fan.enabled = v;
        }
        if let Some(v) = j.get("mode").and_then(|v| v.as_str()) {
            if v == "static" || v == "curve" {
                fan.mode = v.to_string();
            }
        }
        if let Some(v) = json_field_f64(&j, "static_speed") {
            fan.static_speed = v.clamp(0.0, 1.0);
        }
        if let Some(v) = j.get("temperature_key").and_then(|v| v.as_str()) {
            if matches!(v, "edge" | "junction" | "mem") {
                fan.temperature_key = v.to_string();
            }
        }
        // Curve: accept [[temp,speed],...] (frontend) or {"40":0.3,...}.
        let mut pts: Vec<(f64, f64)> = Vec::new();
        if let Some(arr) = j.get("curve").and_then(|v| v.as_arr()) {
            for pair in arr {
                if let Some(q) = pair.as_arr() {
                    if let (Some(t), Some(sp)) = (
                        q.first().and_then(|v| v.as_f64()),
                        q.get(1).and_then(|v| v.as_f64()),
                    ) {
                        pts.push((t, sp));
                    }
                }
            }
        } else if let Some(obj) = j.get("curve") {
            for (k, v) in obj.entries() {
                if let (Ok(t), Some(sp)) = (k.parse::<f64>(), v.as_f64()) {
                    pts.push((t, sp));
                }
            }
        }
        if !pts.is_empty() {
            fan.curve = normalize_curve(&pts);
        }

        // The PMFW limits are plain sysfs scalars. Clamp to the range the
        // kernel advertises before writing: an out-of-range value is rejected
        // with EINVAL, which would fail the request partway through and leave
        // the saved config disagreeing with the hardware.
        let num = |key: &str, name: &str, range_key: &str| -> Result<(), String> {
            let Some(v) = json_field_f64(&j, key) else {
                return Ok(());
            };
            let path = format!("{}/{}", p.fan_ctrl, name);
            let v = match read_od_block(&path, range_key) {
                Some((_, min, max)) if max > min => v.clamp(min, max),
                _ => v,
            };
            write_file_retry(&path, &format!("{}\n", v.round() as i64))
        };
        num("minimum_pwm", "fan_minimum_pwm", "MINIMUM_PWM")?;
        num("target_temperature", "fan_target_temperature", "TARGET_TEMPERATURE")?;
        num(
            "acoustic_target",
            "acoustic_target_rpm_threshold",
            "ACOUSTIC_TARGET",
        )?;
        num(
            "acoustic_limit",
            "acoustic_limit_rpm_threshold",
            "ACOUSTIC_LIMIT",
        )?;
        if let Some(v) = json_field_bool(&j, "zero_rpm") {
            write_file_retry(
                &format!("{}/fan_zero_rpm_enable", p.fan_ctrl),
                if v { "1\n" } else { "0\n" },
            )?;
        }

        s.fan = fan;
        (s.fan.mode.clone(), s.fan.enabled)
    };
    // Force a rewrite even if the curve happens to be unchanged.
    sh.last_curve.lock().unwrap().clear();
    sh.save();
    Ok(format!("fan updated (enabled={enabled}, mode={mode})"))
}

fn apply_power(sh: &Shared, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let cap = json_field_f64(&j, "cap");
    let watts = cap.unwrap_or_else(|| {
        read_f64(&sh.paths.power_cap_default).unwrap_or(0.0) / 1_000_000.0
    });
    set_power_cap(&sh.paths, watts)?;
    {
        let mut s = sh.settings.lock().unwrap();
        s.power_cap = cap;
    }
    sh.save();
    Ok(match cap {
        Some(v) => format!("power cap set to {} W", fnum(v)),
        None => format!("power cap reset to default ({} W)", fnum(watts)),
    })
}

fn apply_perf(sh: &Shared, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let level = j
        .get("level")
        .and_then(|v| v.as_str())
        .ok_or("missing level")?
        .to_string();
    set_perf_level(&sh.paths, &level)?;
    {
        let mut s = sh.settings.lock().unwrap();
        s.perf_level = level.clone();
    }
    sh.save();
    Ok(format!("performance level set to {level}"))
}

fn apply_clocks(sh: &Shared, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let p = &sh.paths;

    if json_field_bool(&j, "reset").unwrap_or(false) {
        reset_clocks(p)?;
        {
            let mut s = sh.settings.lock().unwrap();
            s.clocks = None;
            s.clocks_pending = false;
        }
        sh.save();
        return Ok("clocks reset to firmware defaults".to_string());
    }

    // Merge onto the saved values so a single-field update does not zero the
    // rest; the OD table always gets a complete, self-consistent write.
    let mut c = sh
        .settings
        .lock()
        .unwrap()
        .clocks
        .clone()
        .unwrap_or_default();
    if let Some(v) = json_field_f64(&j, "gpu_clock_offset") {
        c.gpu_clock_offset = v;
    }
    if let Some(v) = json_field_f64(&j, "voltage_offset") {
        c.voltage_offset = v;
    }
    if let Some(v) = json_field_f64(&j, "min_memory_clock") {
        c.min_memory_clock = v;
    }
    if let Some(v) = json_field_f64(&j, "max_memory_clock") {
        c.max_memory_clock = v;
    }
    // Untouched VRAM clocks come from the table the firmware handed us.
    if let Some(od) = read_od_table(&p.od_clk_voltage) {
        if c.min_memory_clock == 0.0 {
            c.min_memory_clock = od.mclk_min;
        }
        if c.max_memory_clock == 0.0 {
            c.max_memory_clock = od.mclk_max;
        }
    }
    push_clocks(p, &c)?;
    {
        let mut s = sh.settings.lock().unwrap();
        s.clocks = Some(c);
        // Confidence is only earned by surviving a clean shutdown: see the
        // pending-check at startup.
        s.clocks_pending = true;
    }
    sh.save();
    Ok("clocks updated".to_string())
}

fn apply_thermal(sh: &Shared, body: &str) -> Result<String, String> {
    let j = body_json(body);
    let action = j
        .get("action")
        .and_then(|v| v.as_str())
        .unwrap_or("apply")
        .to_string();

    if action == "stop" {
        sh.thermal.lock().unwrap().disarm();
        sh.last_curve.lock().unwrap().clear();
        sh.save();
        // Hand the fan back to the firmware straight away rather than waiting
        // for the fan thread's next tick.
        return reset_fan_curve(&sh.paths.fan_ctrl)
            .map(|_| "PID controller stopped; fan returned to GPU firmware".to_string());
    }

    let (target, source, kp, ki, kd) = {
        let mut th = sh.thermal.lock().unwrap();
        th.apply_json(&j);
        th.enabled = true;
        th.active = true;
        th.reset_loop();
        (th.target, th.source.clone(), th.kp, th.ki, th.kd)
    };
    sh.last_curve.lock().unwrap().clear();
    sh.save();
    Ok(format!(
        "PID armed: target {target} °C on {source} temp (kp={kp}, ki={ki}, kd={kd})"
    ))
}
/// Put every knob back to the firmware default and clear the saved overrides.
/// This replaces the daemon's "revert unconfirmed change" timer: writes take
/// effect immediately and are only undone here or by the control that owns
/// them.
fn reset_all(sh: &Shared) -> Result<String, String> {
    let p = &sh.paths;
    let mut notes: Vec<String> = Vec::new();
    if reset_clocks(p).is_ok() {
        notes.push("clocks".to_string());
    }
    if !p.fan_ctrl.is_empty() {
        let _ = reset_fan_curve(&p.fan_ctrl);
        notes.push("fan".to_string());
    }
    if let Some(v) = read_f64(&p.power_cap_default) {
        let _ = set_power_cap(p, v / 1_000_000.0);
        notes.push("power cap".to_string());
    }
    let _ = set_perf_level(p, "auto");
    {
        let mut s = sh.settings.lock().unwrap();
        *s = Settings::default();
    }
    sh.thermal.lock().unwrap().disarm();
    sh.last_curve.lock().unwrap().clear();
    sh.save();
    Ok(format!("reset to firmware defaults ({})", notes.join(", ")))
}

fn handle(mut s: TcpStream, sh: Arc<Shared>) {
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
                let body = snapshot_json(&sh);
                send_json(&mut s, "200 OK", &body);
                return;
            }
            "/api/control" => {
                let c = sh.ctl();
                send_json(&mut s, "200 OK", &c.to_json());
                return;
            }
            "/api/thermal" => {
                let t = sh.thermal.lock().unwrap().to_json();
                send_json(&mut s, "200 OK", &t);
                return;
            }
            "/api/stream" => {
                sse_stream(s, sh);
                return;
            }
            "/api/health" => {
                let c = sh.ctl();
                send_json(
                    &mut s,
                    "200 OK",
                    &format!(
                        "{{\"ok\":true,\"sysfs\":{},\"gpu\":\"{}\"}}",
                        c.ok,
                        json_escape(&sh.paths.dev)
                    ),
                );
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
        "/api/fan" => apply_fan(&sh, &req.body),
        "/api/power" => apply_power(&sh, &req.body),
        "/api/perf" => apply_perf(&sh, &req.body),
        "/api/clocks" => apply_clocks(&sh, &req.body),
        "/api/thermal" => apply_thermal(&sh, &req.body),
        "/api/reset" => reset_all(&sh),
        _ => {
            send_text(&mut s, "404 Not Found", "not found");
            return;
        }
    };

    match result {
        Ok(msg) => {
            log(&format!("{path}: {msg}"));
            send_json(&mut s, "200 OK", &format!("{{\"ok\":true,\"message\":\"{}\",\"control\":{}}}",
                json_escape(&msg), sh.ctl().to_json()));
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
    let mut interval_ms: u64 = 500;
    let mut history_secs: u64 = 1800;
    let mut state_path = "/var/lib/gpu-panel/settings.json".to_string();

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
            "--interval-ms" => interval_ms = need(i).parse().unwrap_or(500),
            "--history-secs" => history_secs = need(i).parse().unwrap_or(1800),
            "--state" => state_path = need(i),
            "-h" | "--help" => {
                println!(
                    "gpu-panel [--listen ADDR] [--pci BDF] [--interval-ms N] [--history-secs N] [--state PATH]"
                );
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
    if paths.fan_ctrl.is_empty() {
        log("warning: no gpu_od/fan_ctrl -- fan control unavailable (need amdgpu.ppfeaturemask=0xffffffff)");
    }
    for (label, _) in &paths.temps {
        log(&format!("  temperature sensor: {label}"));
    }

    let history_cap = ((history_secs * 1000) / interval_ms.max(1)) as usize;
    // One-time migration: the state file was `thermal.json` before the panel
    // grew the fan/power/perf/clock overrides. Fall back to it if the new name
    // is not there yet, so an armed loop and saved settings survive the
    // upgrade; the first save writes the new name.
    let legacy = std::path::Path::new(&state_path)
        .parent()
        .map(|d| d.join("thermal.json"))
        .unwrap_or_default();
    let (thermal, mut settings) = state_load(&state_path)
        .or_else(|| state_load(&legacy.to_string_lossy()))
        .unwrap_or_default();

    // A clock/voltage change that is still pending means the last session did
    // not exit cleanly. Treat it as the suspect and revert rather than
    // re-apply: an unstable undervolt restored on every boot would leave the
    // machine impossible to bring up.
    if settings.clocks_pending {
        log("warning: an unconfirmed clock/voltage change was live when this host went down; reverting instead of re-applying");
        if let Err(e) = reset_clocks(&paths) {
            log(&format!("warning: could not revert clocks: {e}"));
        }
        settings.clocks = None;
        settings.clocks_pending = false;
        // Persist the revert so the file matches reality, and so a second
        // crash immediately afterwards re-reverts rather than retrying.
        state_save(&state_path, &thermal, &settings);
    }
    if thermal.enabled {
        log(&format!(
            "restoring armed PID thermal controller from saved state (target {} C on {} temp)",
            fnum(thermal.target),
            thermal.source
        ));
    }

    // Re-apply the saved hardware settings. This is what makes a control set in
    // the web UI survive a restart: the panel is the only writer now, so
    // nothing else would put them back.
    match settings.power_cap {
        Some(w) => {
            if let Err(e) = set_power_cap(&paths, w) {
                log(&format!("warning: could not restore power cap: {e}"));
            }
        }
        None => {
            if let Some(v) = read_f64(&paths.power_cap_default) {
                let _ = set_power_cap(&paths, v / 1_000_000.0);
            }
        }
    }
    if let Err(e) = set_perf_level(&paths, &settings.perf_level) {
        log(&format!("warning: could not restore performance level: {e}"));
    }
    if let Some(c) = &settings.clocks {
        if let Err(e) = push_clocks(&paths, c) {
            log(&format!("warning: could not restore clocks: {e}"));
        }
    }
    log(&format!(
        "settings: fan={} {} @{} temp, perf={}, cap={}, clocks={}",
        settings.fan.mode,
        if settings.fan.enabled { "enabled" } else { "disabled" },
        settings.fan.temperature_key,
        settings.perf_level,
        match settings.power_cap {
            Some(v) => format!("{} W", fnum(v)),
            None => "firmware default".to_string(),
        },
        if settings.clocks.is_some() {
            "restored"
        } else {
            "firmware default"
        }
    ));

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
        thermal: Mutex::new(thermal),
        settings: Mutex::new(settings),
        last_curve: Mutex::new(Vec::new()),
        paths: paths.clone(),
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

    // Fan thread: the single writer of the fan curve. It writes the PID curve
    // while the thermal loop is armed, the configured curve while fan control is
    // enabled, and hands the fan back to the firmware otherwise (including at
    // shutdown, so a crash cannot leave the GPU with a stale curve).
    {
        let sh = sh.clone();
        let paths = paths.clone();
        thread::Builder::new()
            .name("fan".into())
            .spawn(move || {
                let mut owned = false;
                loop {
                    if SHUTDOWN.load(Ordering::SeqCst) {
                        if owned {
                            let _ = reset_fan_curve(&paths.fan_ctrl);
                            log("shutdown: fan control returned to GPU firmware");
                        }
                        // A clean exit confirms the clock/voltage settings: they
                        // have survived a session, so let them be re-applied on
                        // the next boot instead of being treated as suspect.
                        let confirm = {
                            let mut s = sh.settings.lock().unwrap();
                            let was = s.clocks_pending;
                            s.clocks_pending = false;
                            was
                        };
                        if confirm {
                            sh.save();
                            log("shutdown: clock/voltage settings confirmed");
                        }
                        std::process::exit(0);
                    }

                    let (armed, interval, source) = {
                        let th = sh.thermal.lock().unwrap();
                        (th.enabled && th.active, th.interval_ms, th.source.clone())
                    };
                    let cfg = sh.settings.lock().unwrap().fan.clone();

                    let want: Option<(Vec<(i32, f64)>, u64)> = if armed {
                        let temp = fan_source_temp(&paths, &source);
                        // The firmware curve x-axis is the hotspot, so shift the
                        // centre by the sensor offset to line the ramp up with
                        // whichever sensor we regulate.
                        let hotspot = temp_by_label(&paths, "junction");
                        let now = now_ms();
                        let curve = {
                            let mut th = sh.thermal.lock().unwrap();
                            let duty = th.step(temp, hotspot, now);
                            let offset =
                                (hotspot - temp).clamp(0.0, (100.0 - th.target).max(0.0));
                            th.center = th.target + offset;
                            th.last_update_ms = now;
                            build_pid_curve(th.center, duty, th.duty_min)
                        };
                        Some((curve, interval))
                    } else if cfg.enabled && !paths.fan_ctrl.is_empty() {
                        Some((fan_curve_for(&cfg), 500))
                    } else {
                        None
                    };

                    match want {
                        Some((curve, sleep_ms)) => {
                            let same = {
                                let last = sh.last_curve.lock().unwrap();
                                curve_eq(&last, &curve)
                            };
                            if !same {
                                match write_fan_curve(&paths.fan_ctrl, &curve) {
                                    Ok(_) => {
                                        *sh.last_curve.lock().unwrap() = curve;
                                        owned = true;
                                        if armed {
                                            let mut th = sh.thermal.lock().unwrap();
                                            th.writes += 1;
                                            th.last_error.clear();
                                        }
                                    }
                                    Err(e) => {
                                        if armed {
                                            sh.thermal.lock().unwrap().last_error = e.clone();
                                        }
                                        log(&format!("fan curve write failed: {e}"));
                                    }
                                }
                            }
                            thread::sleep(Duration::from_millis(sleep_ms.clamp(250, 10_000)));
                        }
                        None => {
                            if owned {
                                let _ = reset_fan_curve(&paths.fan_ctrl);
                                sh.last_curve.lock().unwrap().clear();
                                log("fan control released; returned to GPU firmware");
                                owned = false;
                            }
                            thread::sleep(Duration::from_millis(500));
                        }
                    }
                }
            })
            .expect("spawn fan controller");
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
        let sh2 = sh.clone();
        thread::Builder::new()
            .name("conn".into())
            .spawn(move || handle(s, sh2))
            .ok();
    }
}
