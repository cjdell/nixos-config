//! fah-panel — folding@home heater telemetry web panel.
//!
//! One app for every space heater in the fleet. The folding-box sibling of
//! gpu-panel (which drives zen3's R9700 through sysfs overdrive): the heater
//! boxes differ in what their GPU exposes, so the panel has a GPU backend per
//! vendor behind one Sample schema, and the frontend/HTTP/SSE half is shared.
//!
//! * `--gpu nvidia` — GTX 970 (hp-z240): the proprietary driver exposes no
//!   sysfs, so telemetry comes from `nvidia-smi --query-gpu` polling and the
//!   control is `nvidia-smi -pl` (NVML power cap).
//! * `--gpu amd` — RX 5700 XT (zen1): amdgpu exposes everything natively in
//!   sysfs (gpu_busy_percent, hwmon temps/power, pp_dpm clock tables); the
//!   control is a write to `hwmon/power1_cap` (microwatts), which works with
//!   the default ppfeaturemask on Navi 10 (verified on zen1).
//! * `--gpu auto` (default) — nvidia when `--nvidia-smi` is given, otherwise
//!   the first PCI device whose hwmon exports `power1_average` (amdgpu).
//!
//! The CPU columns are cross-vendor sysfs reads (coretemp/k10temp hwmon,
//! per-core cpufreq, RAPL package power), because the whole point of these
//! boxes is that CPU and GPU are fighting over the same small PSU.
//!
//! Zero dependencies: std only, frontend embedded via include_str!.
//!
//! ```text
//!                     ┌─ nvidia: nvidia-smi --query-gpu / -pl
//! browser ──HTTP/SSE──> fah-panel ─┤
//!                     └─ amd:      /sys/bus/pci/devices/*/{gpu_busy_percent,pp_dpm_*,hwmon}
//!                           └────> /sys: coretemp|k10temp hwmon, cpufreq, RAPL
//! ```

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
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

/// Lowercased sysfs id file (`vendor` / `device`) of a PCI device dir.
fn id_of(dir: &str, which: &str) -> String {
    read_trim(&format!("{dir}/{which}")).map(|s| s.to_ascii_lowercase()).unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Backend trait
// ---------------------------------------------------------------------------

/// Static-ish identity + power-cap range shown in the panel header/control.
struct GpuInfo {
    kind: &'static str,
    name: String,
    driver: String,
    /// Power-cap range; (0,0) = unsupported and the UI hides the slider.
    cap_min: f64,
    cap_max: f64,
    /// Hardware default cap; 0 = unknown (then the UI omits it).
    cap_default: f64,
}

/// One GPU vendor backend: produce the shared Sample schema and set the one
/// wattage knob the card exposes. Implementations must be cheap to call from
/// both the sampler thread and HTTP handler threads.
trait GpuBackend: Send + Sync {
    fn info(&self) -> GpuInfo;
    fn sample(&self) -> Sample;
    fn set_cap(&self, w: f64) -> Result<String, String>;
}

// ---------------------------------------------------------------------------
// NVIDIA backend (nvidia-smi)
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

struct Nvidia {
    smi: String,
    name: String,
    driver: String,
    /// Power-cap range from power.min_limit/max_limit; (0,0) = unsupported.
    cap_min: f64,
    cap_max: f64,
}

impl Nvidia {
    /// Startup identity queries (non-fatal: nvidia-smi may answer only a
    /// moment later; every error just shows up as `no data` in the UI).
    fn new(smi: &str, name_override: &str) -> Nvidia {
        let name = nvidia_smi(smi, &["--query-gpu=name", "--format=csv,noheader"])
            .unwrap_or_else(|e| {
                eprintln!("fah-panel: nvidia-smi not usable yet: {e}");
                "NVIDIA GPU".into()
            })
            .lines()
            .next()
            .unwrap_or("NVIDIA GPU")
            .to_string();
        let driver = nvidia_smi(smi, &["--query-gpu=driver_version", "--format=csv,noheader"])
            .unwrap_or_default()
            .lines()
            .next()
            .unwrap_or_default()
            .to_string();
        // Power-cap range; "N/A" fields (no support) become (0, 0) -> slider hidden.
        let (cap_min, cap_max) = match nvidia_smi(
            smi,
            &["--query-gpu=power.min_limit,power.max_limit", "--format=csv,noheader,nounits"],
        ) {
            Ok(line) => {
                let f: Vec<&str> =
                    line.lines().next().unwrap_or("").split(',').map(|c| c.trim()).collect();
                (
                    f.first().and_then(|v| v.parse().ok()).unwrap_or(0.0),
                    f.get(1).and_then(|v| v.parse().ok()).unwrap_or(0.0),
                )
            }
            Err(_) => (0.0, 0.0),
        };
        Nvidia {
            smi: smi.to_string(),
            name: pick_name(name_override, name),
            driver,
            cap_min,
            cap_max,
        }
    }
}

/// `--gpu-name` override if non-empty, else the backend's own discovery.
fn pick_name(override_name: &str, discovered: String) -> String {
    if override_name.trim().is_empty() {
        discovered
    } else {
        override_name.trim().to_string()
    }
}

impl GpuBackend for Nvidia {
    fn info(&self) -> GpuInfo {
        GpuInfo {
            kind: "nvidia",
            name: self.name.clone(),
            driver: self.driver.clone(),
            cap_min: self.cap_min,
            cap_max: self.cap_max,
            // The legacy 580 branch has no default_power_limit query field.
            cap_default: 0.0,
        }
    }

    fn sample(&self) -> Sample {
        take_sample(&self.smi)
    }

    fn set_cap(&self, w: f64) -> Result<String, String> {
        nvidia_smi(&self.smi, &["-pl", &w.to_string()]).map(|m| m.replace('\n', " "))
    }
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
    /// amdgpu performance level ("auto"/"peak"/…); empty on nvidia.
    perf: String,
    throttle: Vec<&'static str>,
    /// CPU package (RAPL) + GPU board power (NVML/amdgpu) = what the +12 V
    /// rail is being asked to supply. There are no real rail sensors on these
    /// boards (the HP Super-I/O hwmon exposes nothing but a dead pwm1; no
    /// BMC), so this estimate plus the boot-time behaviour is the brownout
    /// monitor.
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
             \"pstate\":\"{}\",\"perf\":\"{}\",\"throttle\":[{}],\"cpu_temp\":{},\"cpu_power\":{},\"total\":{},\
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
            json_escape(&self.perf),
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
        let Ok(out) = Command::new(dmi).args(args).stdin(Stdio::null()).output() else {
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
// AMD backend (amdgpu sysfs)
// ---------------------------------------------------------------------------
//
// Everything the panel shows is a native amdgpu sysfs read (same sources as
// gpu-panel on zen3): gpu_busy_percent, mem_info_vram_*, hwmon temps labelled
// edge/junction/mem, power1_average/power1_cap in microwatts, pwm1 0..255,
// and the current+max clocks out of the pp_dpm_sclk/pp_dpm_mclk tables. The
// control is a write to power1_cap — verified on the RX 5700 XT (Navi 10)
// with the *default* ppfeaturemask: no overdrive bits needed for the cap.

#[derive(Clone)]
struct AmdPaths {
    dev: String,
    hwmon: String,
    /// hwmon temperature inputs keyed by their label ("edge"/"junction"/"mem").
    temps: Vec<(String, String)>,
}

/// The sysfs PCI device dirs `spec` names: empty spec = every device that
/// exports an hwmon (amdgpu is the only driver exporting power1_average
/// there); `vendor:device` = every match sorted by BDF (deterministic);
/// a full BDF = that one device. (Same resolution model as gpu-panel —
/// DRM card numbers and BDFs shuffle between boots, ids do not.)
fn amd_candidates(spec: &str) -> Result<Vec<String>, String> {
    let s = spec.trim().to_ascii_lowercase();
    let mut out = Vec::new();
    if s.is_empty() {
        if let Ok(rd) = std::fs::read_dir("/sys/bus/pci/devices") {
            for e in rd.flatten() {
                let dir = format!("/sys/bus/pci/devices/{}", e.file_name().to_string_lossy());
                if std::path::Path::new(&format!("{dir}/hwmon")).exists() {
                    out.push(dir);
                }
            }
        }
        out.sort();
        if out.is_empty() {
            return Err("no PCI device exports an hwmon (amdgpu not loaded?)".into());
        }
        return Ok(out);
    }
    if s.matches(':').count() == 3 {
        return Ok(vec![format!("/sys/bus/pci/devices/{s}")]);
    }
    let (vendor, device) = s.split_once(':').ok_or_else(|| {
        format!("expected a PCI BDF (0000:0c:00.0) or a vendor:device id (1002:731f), got {spec}")
    })?;
    let want = (format!("0x{vendor}"), format!("0x{device}"));
    if let Ok(rd) = std::fs::read_dir("/sys/bus/pci/devices") {
        for e in rd.flatten() {
            let dir = format!("/sys/bus/pci/devices/{}", e.file_name().to_string_lossy());
            if (id_of(&dir, "vendor"), id_of(&dir, "device")) == want {
                out.push(dir);
            }
        }
    }
    out.sort();
    if out.is_empty() {
        return Err(format!("no PCI device with id {s}"));
    }
    Ok(out)
}

/// The amdgpu hwmon directory under `dev` (the one exporting power1_average).
fn find_hwmon(dev: &str) -> Result<String, String> {
    if !std::path::Path::new(dev).exists() {
        return Err(format!("no such PCI device: {dev}"));
    }
    std::fs::read_dir(format!("{dev}/hwmon"))
        .map_err(|e| format!("{dev}/hwmon: {e}"))?
        .flatten()
        .map(|e| format!("{dev}/hwmon/{}", e.file_name().to_string_lossy()))
        .find(|p| std::path::Path::new(&format!("{p}/power1_average")).exists())
        .ok_or_else(|| format!("no amdgpu hwmon (power1_average) under {dev}"))
}

fn resolve_amd(spec: &str) -> Result<AmdPaths, String> {
    let mut errs = Vec::new();
    for dev in amd_candidates(spec)? {
        match find_hwmon(&dev) {
            Ok(hwmon) => {
                let mut temps = Vec::new();
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
                return Ok(AmdPaths { dev, hwmon, temps });
            }
            Err(e) => errs.push(e),
        }
    }
    Err(errs.join("; "))
}

/// Parse a `pp_dpm_*` table: (current MHz — the `*`-marked line — and the
/// table maximum, e.g. "0: 300Mhz\n1: 1650Mhz *").
fn dpm_clocks(path: &str) -> (f64, f64) {
    let Some(text) = read_trim(path) else {
        return (0.0, 0.0);
    };
    let (mut cur, mut max) = (0.0, 0.0);
    for line in text.lines() {
        let after = line.split(':').nth(1).unwrap_or("");
        let digits: String = after.trim().chars().take_while(|c| c.is_ascii_digit()).collect();
        let Ok(mhz) = digits.parse::<f64>() else { continue };
        if mhz > max {
            max = mhz;
        }
        if line.contains('*') {
            cur = mhz;
        }
    }
    (cur, max)
}

fn amd_temp_by(p: &AmdPaths, label: &str) -> f64 {
    p.temps
        .iter()
        .find(|(l, _)| l == label)
        .and_then(|(_, path)| read_f64(path))
        .map(|v| v / 1000.0)
        .unwrap_or(0.0)
}

fn amd_temp_hottest(p: &AmdPaths) -> f64 {
    p.temps
        .iter()
        .filter_map(|(_, path)| read_f64(path))
        .map(|v| v / 1000.0)
        .fold(0.0f64, f64::max)
}

struct Amd {
    spec: String,
    name: String,
    driver: String,
    paths: Mutex<Option<AmdPaths>>,
}

impl Amd {
    fn new(spec: &str, name_override: &str) -> Amd {
        let kernel =
            read_trim("/proc/sys/kernel/osrelease").unwrap_or_else(|| "unknown".to_string());
        // Resolve once at startup for the log line and the id fallback name;
        // failure is not fatal (boot race, GPU init later — every sample
        // re-resolves until it succeeds).
        let resolved = resolve_amd(spec).ok();
        let discovered = match &resolved {
            Some(p) => {
                format!("{}:{}", id_of(&p.dev, "vendor").trim_start_matches("0x"),
                        id_of(&p.dev, "device").trim_start_matches("0x"))
            }
            None => "AMD GPU".to_string(),
        };
        Amd {
            spec: spec.to_string(),
            name: pick_name(name_override, discovered),
            driver: format!("amdgpu (kernel {kernel})"),
            paths: Mutex::new(resolved),
        }
    }

    /// Cached device paths, re-resolving when unknown or when the PCI device
    /// vanished (re-enumeration, driver reload).
    fn paths(&self) -> Result<AmdPaths, String> {
        let mut g = self.paths.lock().unwrap();
        if let Some(p) = g.as_ref() {
            if std::path::Path::new(&p.dev).exists() {
                return Ok(p.clone());
            }
        }
        *g = None;
        let p = resolve_amd(&self.spec)?;
        *g = Some(p.clone());
        Ok(p)
    }
}

impl GpuBackend for Amd {
    fn info(&self) -> GpuInfo {
        // Read the cap range live: the files are static in practice, but
        // reading them on every /api/health also covers a card whose paths
        // resolved only after startup.
        let (mut cmin, mut cmax, mut cdef) = (0.0, 0.0, 0.0);
        if let Ok(p) = self.paths() {
            cmin = read_f64(&format!("{}/power1_cap_min", p.hwmon)).unwrap_or(0.0) / 1e6;
            cmax = read_f64(&format!("{}/power1_cap_max", p.hwmon)).unwrap_or(0.0) / 1e6;
            cdef = read_f64(&format!("{}/power1_cap_default", p.hwmon)).unwrap_or(0.0) / 1e6;
        }
        GpuInfo {
            kind: "amd",
            name: self.name.clone(),
            driver: self.driver.clone(),
            cap_min: cmin,
            cap_max: cmax,
            cap_default: cdef,
        }
    }

    fn sample(&self) -> Sample {
        let mut s = Sample::default();
        let p = match self.paths() {
            Ok(p) => p,
            Err(e) => {
                s.error = e;
                s.ts = now_ms();
                return s;
            }
        };
        s.util = read_u64(&format!("{}/gpu_busy_percent", p.dev)).unwrap_or(0) as f64;
        // MiB, like the nvidia backend reports memory.used/total.
        s.mem_used = read_u64(&format!("{}/mem_info_vram_used", p.dev)).unwrap_or(0) as f64
            / 1_048_576.0;
        s.mem_total = read_u64(&format!("{}/mem_info_vram_total", p.dev)).unwrap_or(0) as f64
            / 1_048_576.0;
        s.temp = {
            let t = amd_temp_by(&p, "edge");
            if t > 0.0 {
                t
            } else {
                let j = amd_temp_by(&p, "junction");
                if j > 0.0 {
                    j
                } else {
                    amd_temp_hottest(&p)
                }
            }
        };
        // pwm1 is 0..255; the UI wants a percentage (and null -> "auto").
        s.fan = read_u64(&format!("{}/pwm1", p.hwmon)).map(|v| v as f64 * 100.0 / 255.0).unwrap_or(0.0);
        s.power = read_f64(&format!("{}/power1_average", p.hwmon)).unwrap_or(0.0) / 1e6;
        s.power_limit = read_f64(&format!("{}/power1_cap", p.hwmon)).unwrap_or(0.0) / 1e6;
        let (c, cmax) = dpm_clocks(&format!("{}/pp_dpm_sclk", p.dev));
        s.clock_gpu = c;
        s.clock_gpu_max = cmax;
        let (m, mmax) = dpm_clocks(&format!("{}/pp_dpm_mclk", p.dev));
        s.clock_mem = m;
        s.clock_mem_max = mmax;
        s.perf = read_trim(&format!("{}/power_dpm_force_performance_level", p.dev))
            .unwrap_or_else(|| "auto".to_string());
        s.ok = true;
        s.ts = now_ms();
        s
    }

    fn set_cap(&self, w: f64) -> Result<String, String> {
        let p = self.paths()?;
        let path = format!("{}/power1_cap", p.hwmon);
        std::fs::write(&path, format!("{}", (w * 1e6).round() as u64))
            .map_err(|e| format!("{path}: {e}"))?;
        // The SMU accepts the nearest value it supports; echo what stuck.
        match read_f64(&path) {
            Some(v) => Ok(format!("power cap set to {:.0} W", v / 1e6)),
            None => Ok(format!("power cap set to {w:.0} W")),
        }
    }
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

// --- CPU max-temperature auto-throttle (the CPU-side sibling of the cap slider)
//
// A target temperature plus a proportional loop in the sampler: the loop
// walks every cpufreq `scaling_max_freq` ceiling down when the package sensor
// is above the target and lets it drift back to `cpuinfo_max_freq` below it
// (deadband ±0.5 °C, gain 12 MHz/°C, max 40 MHz per tick so a hot chip ramps
// down over ~1 min, not in one jump). On kernels ≥6.9 `policy*/` devices
// exist for every driver — one policy per logical core is normal here
// (amd-pstate-epp on zen3, acpi-cpufreq on zen1, intel_pstate on the z240),
// so every file gets the same ceiling; on older kernels fall back to the
// per-core files. The panel is the single writer, live state only: at startup
// it releases any ceiling left by a previous run, and target → off restores
// the ceiling immediately. (The kernel's own k10temp/coretemp shutdown at
// ~105 °C stays the last line of defence; this slider is about keeping the
// chip — and the PSU next to it — below a chosen temperature.)

struct CpuThrottle {
    files: Vec<String>,
    min_khz: u64,
    max_khz: u64,
}

fn detect_cpu_throttle() -> CpuThrottle {
    let mut files = Vec::new();
    if let Ok(rd) = std::fs::read_dir("/sys/devices/system/cpu/cpufreq") {
        for e in rd.flatten() {
            let f = format!(
                "/sys/devices/system/cpu/cpufreq/{}/scaling_max_freq",
                e.file_name().to_string_lossy()
            );
            if std::path::Path::new(&f).exists() {
                files.push(f);
            }
        }
    }
    files.sort();
    if files.is_empty() {
        let mut found: Vec<(usize, String)> = Vec::new();
        if let Ok(rd) = std::fs::read_dir("/sys/devices/system/cpu") {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                let Some(rest) = name.strip_prefix("cpu") else { continue };
                if rest.is_empty() || !rest.bytes().all(|b| b.is_ascii_digit()) {
                    continue;
                }
                let f = format!("/sys/devices/system/cpu/{name}/cpufreq/scaling_max_freq");
                if std::path::Path::new(&f).exists() {
                    found.push((rest.parse().unwrap_or(usize::MAX), f));
                }
            }
        }
        found.sort_by_key(|(i, _)| *i);
        files = found.into_iter().map(|(_, p)| p).collect();
    }
    let cpu0 = "/sys/devices/system/cpu/cpu0/cpufreq";
    CpuThrottle {
        files,
        min_khz: read_u64(&format!("{cpu0}/cpuinfo_min_freq")).unwrap_or(0),
        max_khz: read_u64(&format!("{cpu0}/cpuinfo_max_freq")).unwrap_or(0),
    }
}

impl CpuThrottle {
    fn available(&self) -> bool {
        !self.files.is_empty() && self.min_khz > 0 && self.max_khz >= self.min_khz
    }

    /// The kernel may clamp a written ceiling (acpi-cpufreq on this 1800X
    /// rounds anything above 3.6 GHz — its top `_PSS` entry — back to 3.6).
    /// Report what is actually enforced, read back from the first policy.
    fn read_cap(&self) -> Option<u64> {
        self.files.first().and_then(|f| read_u64(f))
    }

    fn apply(&self, khz: u64) -> Result<String, String> {
        let mut err = String::new();
        for f in &self.files {
            if let Err(e) = std::fs::write(f, khz.to_string()) {
                if err.is_empty() {
                    err = format!("{f}: {e}");
                }
            }
        }
        if err.is_empty() {
            Ok(format!("cpu ceiling set to {:.2} GHz", khz as f64 / 1e6))
        } else {
            Err(err)
        }
    }
}

/// One proportional step of the ceiling (kHz) toward keeping `temp` at or
/// below `target` (°C): gain 12 MHz/°C clamped to ±40 MHz per tick, a ±0.5 °C
/// deadband, and hard clamped into [min, max]. Returns `cap` unchanged when
/// the sensors/target are unusable.
fn step_cap(cap_khz: u64, temp: f64, target: f64, lo: u64, hi: u64) -> u64 {
    if !temp.is_finite() || temp <= 0.0 || !target.is_finite() || target <= 0.0 {
        return cap_khz;
    }
    let err = target - temp;
    if err.abs() <= 0.5 {
        return cap_khz;
    }
    let step_khz = (err * 12.0).clamp(-40.0, 40.0) * 1000.0;
    (cap_khz as i64 + step_khz.round() as i64).clamp(lo as i64, hi as i64) as u64
}

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

struct Shared {
    backend: Arc<dyn GpuBackend>,
    /// Estimated DC-load budget in watts for the UI to flag against; 0 = off.
    budget: f64,
    /// SMBIOS RAM bus speed (static), empty = unknown.
    ram: String,
    /// Machine name, so several heater panels on the network are told apart.
    host: String,
    /// CPU max-temperature auto-throttle: cpufreq plumbing (static), the
    /// target (°C×100, 0 = off — written by the HTTP thread) and the applied
    /// ceiling in kHz (0 = unmanaged), both owned by the sampler.
    cpu_throttle: Arc<CpuThrottle>,
    cpu_target: AtomicI64,
    cpu_cap_khz: AtomicU64,
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
        let gi = self.backend.info();
        let th = self.cpu_throttle.available();
        let target = self.cpu_target.load(Ordering::SeqCst) as f64 / 100.0;
        let cap_raw = self.cpu_cap_khz.load(Ordering::SeqCst);
        let cpu_cap = if cap_raw == 0 {
            0.0
        } else {
            self.cpu_throttle.read_cap().unwrap_or(cap_raw) as f64 / 1e6
        };
        format!(
            "{{\"ok\":{},\"cap\":{},\"cap_min\":{},\"cap_max\":{},\"cap_default\":{},\"budget\":{},\
             \"cpu_throttle\":{},\"cpu_target\":{},\"cpu_cap\":{},\"cpu_min_ghz\":{},\"cpu_max_ghz\":{},\
             \"gpu\":\"{}\",\"driver\":\"{}\",\"ram\":\"{}\",\"backend\":\"{}\",\"host\":\"{}\"}}",
            cur.contains("\"ok\":true"),
            fnum(cap),
            fnum(gi.cap_min),
            fnum(gi.cap_max),
            fnum_pos(gi.cap_default),
            fnum(self.budget),
            th,
            fnum(target),
            fnum_pos(cpu_cap),
            fnum(self.cpu_throttle.min_khz as f64 / 1e6),
            fnum(self.cpu_throttle.max_khz as f64 / 1e6),
            json_escape(&gi.name),
            json_escape(&gi.driver),
            json_escape(&self.ram),
            gi.kind,
            json_escape(&self.host),
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

/// Pull `"<key>": <number>` out of the flat POST body.
fn body_num(body: &str, key: &str) -> Option<f64> {
    let i = body.find(&format!("\"{key}\""))?;
    let rest = body[i + key.len() + 2..].trim_start();
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
        let gi = sh.backend.info();
        match body_num(&req.body, "cap") {
            Some(w) if gi.cap_max > 0.0 && w >= gi.cap_min && w <= gi.cap_max => {
                match sh.backend.set_cap(w) {
                    Ok(msg) => {
                        log(&format!("power cap set to {w} W: {msg}"));
                        let cur = sh.cur.lock().unwrap().clone();
                        send_json(&mut s, "200 OK", &format!("{{\"ok\":true,\"message\":\"{}\",\"control\":{}}}", json_escape(&msg), sh.control_json(&cur)));
                    }
                    Err(e) => {
                        log(&format!("power cap failed: {e}"));
                        send_json(&mut s, "400 Bad Request", &format!("{{\"ok\":false,\"error\":\"{}\"}}", json_escape(&e)));
                    }
                }
            }
            Some(_) => send_json(&mut s, "400 Bad Request", &format!("{{\"ok\":false,\"error\":\"cap out of range {:.0}–{:.0} W\"}}", gi.cap_min, gi.cap_max)),
            None => send_json(&mut s, "400 Bad Request", "{\"ok\":false,\"error\":\"no numeric cap in body\"}"),
        }
        return;
    }

    if req.method == "POST" && path == "/api/cpu-target" {
        // (ok, message-or-error); 0 = off, otherwise a 30–110 °C target.
        let (ok, msg) = match body_num(&req.body, "target") {
            Some(t) if sh.cpu_throttle.available() && (t == 0.0 || (30.0..=110.0).contains(&t)) => {
                sh.cpu_target.store((t * 100.0).round() as i64, Ordering::SeqCst);
                (
                    true,
                    if t == 0.0 {
                        "CPU auto-throttle off — ceiling released".to_string()
                    } else {
                        format!("CPU auto-throttle target {t:.0} °C")
                    },
                )
            }
            Some(_) if sh.cpu_throttle.available() => {
                (false, "bad target — use 0 (off) or 30–110 °C".into())
            }
            Some(_) => (false, "no writable cpufreq interface on this host".into()),
            None => (false, "no numeric target in body".into()),
        };
        log(&msg);
        if ok {
            let cur = sh.cur.lock().unwrap().clone();
            send_json(&mut s, "200 OK", &format!("{{\"ok\":true,\"message\":\"{}\",\"control\":{}}}", json_escape(&msg), sh.control_json(&cur)));
        } else {
            send_json(&mut s, "400 Bad Request", &format!("{{\"ok\":false,\"error\":\"{}\"}}", json_escape(&msg)));
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
    let mut listen = "0.0.0.0:80".to_string();
    let mut gpu = "auto".to_string();
    let mut smi = String::new();
    let mut amd_pci = String::new();
    let mut gpu_name = String::new();
    let mut interval_ms: u64 = 2000;
    let mut budget: f64 = 0.0;
    let mut dmi = String::new();

    let mut i = 1;
    while i < args.len() {
        let flag = args[i].clone();
        if flag == "--listen"
            || flag == "--gpu"
            || flag == "--nvidia-smi"
            || flag == "--amd-pci"
            || flag == "--gpu-name"
            || flag == "--interval"
            || flag == "--budget"
            || flag == "--dmidecode"
        {
            i += 1;
            let v = args.get(i).cloned().unwrap_or_default();
            match flag.as_str() {
                "--listen" => listen = v,
                "--gpu" => gpu = v,
                "--nvidia-smi" => smi = v,
                "--amd-pci" => amd_pci = v,
                "--gpu-name" => gpu_name = v,
                "--interval" => interval_ms = v.parse().unwrap_or(2000).clamp(500, 60_000),
                "--budget" => budget = v.parse().unwrap_or(0.0),
                "--dmidecode" => dmi = v,
                _ => unreachable!(),
            }
        } else if flag == "--help" || flag == "-h" {
            println!(
                "usage: fah-panel [--listen ADDR:PORT] [--gpu auto|nvidia|amd]\n\
                 [--nvidia-smi PATH] [--amd-pci VENDOR:DEVICE|BDF] [--gpu-name NAME]\n\
                 [--interval MS] [--budget W] [--dmidecode PATH]\n\
                 Backend auto = nvidia when --nvidia-smi is given, else the first PCI\n\
                 device whose hwmon exports power1_average (amdgpu). Port 80 needs root,\n\
                 as does RAPL energy_uj and both power-cap controls — the service runs\n\
                 as root.\n\
                 The power cap is live state: whatever the backend reports is truth, and\n\
                 a boot-time systemd unit (not this panel) owns setting it at startup.\n\
                 The CPU max-temperature slider (POST /api/cpu-target) is live state too:\n\
                 the sampler moves cpufreq scaling_max_freq to hold the package below the\n\
                 target, and a panel start always releases any ceiling from a prior run.\n\
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

    let backend: Arc<dyn GpuBackend> = match gpu.as_str() {
        "nvidia" => {
            if smi.is_empty() {
                eprintln!("fah-panel: --gpu nvidia requires --nvidia-smi PATH (absolute store path)");
                std::process::exit(2);
            }
            Arc::new(Nvidia::new(&smi, &gpu_name))
        }
        "amd" => Arc::new(Amd::new(&amd_pci, &gpu_name)),
        "auto" => {
            if smi.is_empty() {
                Arc::new(Amd::new(&amd_pci, &gpu_name))
            } else {
                Arc::new(Nvidia::new(&smi, &gpu_name))
            }
        }
        other => {
            eprintln!("fah-panel: --gpu must be auto, nvidia or amd (got {other})");
            std::process::exit(2);
        }
    };

    let cpu = detect_cpu();
    let throttle = Arc::new(detect_cpu_throttle());
    // Live state only: whatever the last run (or LACT/whoever) left behind is
    // released at startup, so a ceiling can never outlive the panel that set
    // it and go unobserved.
    if throttle.available() {
        match throttle.apply(throttle.max_khz) {
            Ok(m) => log(&format!("fah-panel: {m} (released any stale ceiling)")),
            Err(e) => log(&format!("fah-panel: cpu ceiling unusable: {e}")),
        }
    }
    let host =
        read_trim("/proc/sys/kernel/hostname").unwrap_or_else(|| "heater".to_string());
    let sh = Arc::new(Shared {
        backend: Arc::clone(&backend),
        budget,
        ram: ram_speed(&dmi),
        host: host.clone(),
        cpu_throttle: Arc::clone(&throttle),
        cpu_target: AtomicI64::new(0),
        cpu_cap_khz: AtomicU64::new(0),
        seq: AtomicU64::new(0),
        cur: Mutex::new(Sample::default().to_json()),
        history: Mutex::new(VecDeque::with_capacity(601)),
        cpu_info: cpu_info_json(&cpu),
    });
    let gi = backend.info();
    log(&format!(
        "fah-panel: host={host} backend={} gpu={} driver={} caps=({},{}) ram=\"{}\" listen={listen} cpu_threads={} cpu_throttle={}",
        gi.kind,
        gi.name,
        gi.driver,
        gi.cap_min,
        gi.cap_max,
        sh.ram,
        cpu.cur_freq.len(),
        throttle.available(),
    ));
    if gi.cap_max == 0.0 {
        log("fah-panel: warning: no power-cap range right now (device not up yet? the slider stays hidden until /api/health sees one)");
    }

    // Sampler: GPU backend poll + CPU sysfs; the CPU numbers ride along in a
    // side JSON so the stream carries everything one sample needs. The
    // sampler is also the ONLY writer of the cpufreq ceilings — the HTTP
    // thread just moves the target, like gpu-panel's fan thread owning the
    // fan outright.
    let throttle = Arc::clone(&sh.cpu_throttle);
    let sh2 = Arc::clone(&sh);
    thread::Builder::new()
        .name("sampler".into())
        .spawn(move || {
            let mut rapl: Option<(i64, u64)> = None;
            loop {
                let mut s = sh2.backend.sample();
                s.cpu_temp = cpu_pkg_temp(&cpu);
                let hot = cpu_temp_by(&cpu, "Core");
                let (clk_avg, clk_max) = cpu_clocks(&cpu);
                s.cpu_power = cpu_power(&cpu, &mut rapl);
                s.total = s.power + s.cpu_power;

                // CPU max-temperature auto-throttle step (see CpuThrottle).
                let mut cap_json = 0.0f64;
                if throttle.available() {
                    let target = sh2.cpu_target.load(Ordering::SeqCst) as f64 / 100.0;
                    let cap = sh2.cpu_cap_khz.load(Ordering::SeqCst);
                    if target <= 0.0 {
                        if cap != 0 {
                            match throttle.apply(throttle.max_khz) {
                                Ok(m) => {
                                    sh2.cpu_cap_khz.store(0, Ordering::SeqCst);
                                    log(&format!("cpu-throttle: {m}"));
                                }
                                Err(e) => log(&format!("cpu-throttle restore failed: {e}")),
                            }
                        }
                    } else if s.cpu_temp > 0.0 {
                        let base = if cap == 0 { throttle.max_khz } else { cap };
                        let next =
                            step_cap(base, s.cpu_temp, target, throttle.min_khz, throttle.max_khz);
                        if next != cap {
                            match throttle.apply(next) {
                                Ok(m) => {
                                    sh2.cpu_cap_khz.store(next, Ordering::SeqCst);
                                    log(&format!("cpu-throttle: {m}"));
                                }
                                Err(e) => log(&format!("cpu-throttle failed: {e}")),
                            }
                        }
                    }
                    cap_json = match sh2.cpu_cap_khz.load(Ordering::SeqCst) {
                        0 => 0.0,
                        c => throttle.read_cap().unwrap_or(c) as f64 / 1e6,
                    };
                }

                let mut j = s.to_json();
                // Splice the remaining CPU fields the sparklines do not need.
                j.pop();
                j.push_str(&format!(
                    ",\"cpu_hot\":{},\"cpu_clk_avg\":{},\"cpu_clk_max\":{},\"cpu_cap\":{}}}",
                    fnum_pos(hot),
                    fnum(clk_avg),
                    fnum(clk_max),
                    fnum_pos(cap_json),
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
