//! sd-gate: on-demand launcher + TCP proxy for sd-server.
//!
//! Always listens on `--listen` (nginx's `/sd-api/` target, 127.0.0.1:8084).
//! On the first connection it spawns the child command (sd-server, which
//! listens on `--upstream`, 127.0.0.1:8085) and relays traffic. When no
//! request has been seen for `--idle` seconds it kills the child — the model
//! is out of the R9700's VRAM again — and the next request loads it back.
//!
//! Before each spawn it checks free VRAM (`--vram-tool`, amd-smi): if less
//! than `--min-vram-gib` is available it asks llama-swap to unload its model
//! (`--llm-unload-url`) and waits for the VRAM to be freed, so SDXL gets a
//! fast (non-GTT-spill) run instead of sharing the GPU.
//!
//! A second listener (`--status-listen`, 127.0.0.1:8086) serves a status
//! page (HTML at `/`, JSON at `/status`) showing why the model is running:
//! state, idle-unload countdown, VRAM, and the list of active clients
//! (client IP from nginx's X-Forwarded-For, method, path).
//!
//! Zero dependencies: Rust std only (one libc symbol via `extern "C"`).

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const PIDFILE: &str = "/run/sd-gate.pid";

extern "C" {
    fn signal(n: i32, handler: usize) -> usize;
}

const SIGINT: i32 = 2;
const SIGTERM: i32 = 15;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

/// Signal handler: only flips a flag (nothing else is async-signal-safe);
/// the main loop does the actual cleanup.
extern "C" fn on_signal(_sig: i32) {
    SHUTDOWN.store(true, Ordering::SeqCst);
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn log(msg: &str) {
    eprintln!("[sd-gate] {msg}");
}

/// Format unix ms as "YYYY-MM-DD HH:MM:SS UTC" (civil-from-days algorithm).
fn human_time(ms: i64) -> String {
    let secs = ms.div_euclid(1000).max(0);
    let days = (secs / 86400) as i64;
    let rem = secs % 86400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let mut y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    if mo <= 2 {
        y += 1;
    }
    format!("{y:04}-{mo:02}-{d:02} {h:02}:{m:02}:{s:02} UTC")
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

// ---------------------------------------------------------------------------
// VRAM
// ---------------------------------------------------------------------------

struct Vram {
    free_mb: i64,
    total_mb: i64,
    checked_ms: i64,
}

impl Vram {
    fn clone(&self) -> Vram {
        Vram {
            free_mb: self.free_mb,
            total_mb: self.total_mb,
            checked_ms: self.checked_ms,
        }
    }
}

/// Extract `"key": { "value": N, ... }` (N in MB) from `amd-smi metric -m --json`.
fn extract_mb(s: &str, key: &str) -> Option<i64> {
    let i = s.find(&format!("\"{key}\""))?;
    let rest = &s[i..];
    let v = rest.find("\"value\"")?;
    let digits: String = rest[v..]
        .chars()
        .skip_while(|c| !c.is_ascii_digit())
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

/// Free/total VRAM of the first GPU, via `amd-smi metric -m --json`.
fn read_vram(tool: &str) -> Option<Vram> {
    let out = Command::new(tool)
        .args(["metric", "-m", "--json"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).into_owned();
    let free_mb = extract_mb(&s, "free_vram")?;
    let total_mb = extract_mb(&s, "total_vram").unwrap_or(0);
    Some(Vram {
        free_mb,
        total_mb,
        checked_ms: now_ms(),
    })
}

// ---------------------------------------------------------------------------
// Minimal HTTP (loopback only)
// ---------------------------------------------------------------------------

fn parse_http_url(url: &str) -> Option<(SocketAddr, String)> {
    let rest = url.strip_prefix("http://")?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let addr: SocketAddr = authority.parse().ok()?;
    Some((addr, path.to_string()))
}

/// Tiny blocking HTTP request; returns the full response text.
fn http_request(method: &str, url: &str, timeout: Duration) -> Option<String> {
    let (addr, path) = parse_http_url(url)?;
    let mut s = TcpStream::connect_timeout(&addr, timeout).ok()?;
    let _ = s.set_read_timeout(Some(timeout));
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n"
    );
    s.write_all(req.as_bytes()).ok()?;
    let mut buf = Vec::new();
    let _ = s.read_to_end(&mut buf);
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// True when the upstream answers `GET /v1/models` with HTTP 200.
fn probe_ready(upstream: &str) -> bool {
    let resp = http_request("GET", &format!("http://{upstream}/v1/models"), Duration::from_secs(5));
    match resp.and_then(|r| r.lines().next().map(|l| l.to_string())) {
        Some(line) => line.starts_with("HTTP/1.") && line.contains(" 200 "),
        None => false,
    }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

struct Server {
    child: Option<Child>,
}

struct Counts {
    requests: u64,
    spawns: u64,
    idle_kills: u64,
    llm_unloads: u64,
    spawn_failures: u64,
}

struct ClientInfo {
    remote: String,
    method: String,
    path: String,
    since_ms: i64,
    relaying: AtomicBool,
}

struct Cfg {
    listen: String,
    status_listen: String,
    upstream: String,
    idle: Duration,
    ready_timeout: Duration,
    vram_tool: String,
    min_vram_gib: f64,
    llm_unload_url: String,
    vram_wait: Duration,
    cmd: Vec<String>,
}

struct Shared {
    server: Mutex<Server>,
    /// One thread at a time may spawn the child.
    starting: AtomicBool,
    /// Child is running *and* serving requests (or adopted, see below).
    ready: AtomicBool,
    /// A pre-existing sd-server (e.g. orphaned by a crashed gate) is serving.
    adopted: AtomicBool,
    /// Connections currently being handled (waiting on start or relaying).
    clients: AtomicUsize,
    client_list: Mutex<Vec<Arc<ClientInfo>>>,
    last_active_ms: AtomicI64,
    spawned_at_ms: AtomicI64,
    ready_at_ms: AtomicI64,
    vram: Mutex<Option<Vram>>,
    counts: Mutex<Counts>,
}

impl Shared {
    /// The sd-server process we spawned is still alive.
    fn child_alive(&self) -> bool {
        let mut srv = self.server.lock().unwrap();
        srv.child
            .as_mut()
            .is_some_and(|c| c.try_wait().is_ok_and(|s| s.is_none()))
    }

    /// Server is up and can serve requests (spawned or adopted).
    fn server_up(&self) -> bool {
        self.ready.load(Ordering::SeqCst)
            && (self.adopted.load(Ordering::SeqCst) || self.child_alive())
    }

    fn state(&self) -> &'static str {
        if SHUTDOWN.load(Ordering::SeqCst) {
            "stopping"
        } else if self.server_up() {
            "ready"
        } else if self.starting.load(Ordering::SeqCst) {
            "starting"
        } else {
            "idle"
        }
    }
}

fn kill_child(sh: &Shared) {
    let mut srv = sh.server.lock().unwrap();
    if let Some(mut c) = srv.child.take() {
        let _ = c.kill();
        let _ = c.wait();
        log("sd-server killed");
    }
    sh.ready.store(false, Ordering::SeqCst);
    let _ = std::fs::remove_file(PIDFILE);
}

/// If free VRAM is below the threshold, ask llama-swap to unload its model
/// and wait (up to cfg.vram_wait) for the VRAM to be freed. Never blocks the
/// spawn forever: if the VRAM stays low we proceed (sd-server degrades to
/// GTT-spill speed rather than refusing to run).
fn ensure_vram(sh: &Shared, cfg: &Cfg) {
    let min_mb = (cfg.min_vram_gib * 1024.0) as i64;
    let v = match read_vram(&cfg.vram_tool) {
        Some(v) => v,
        None => {
            log(&format!("VRAM check via {vram_tool} failed; proceeding", vram_tool = cfg.vram_tool));
            return;
        }
    };
    *sh.vram.lock().unwrap() = Some(v.clone());
    if v.free_mb >= min_mb {
        return;
    }
    if cfg.llm_unload_url.is_empty() {
        log(&format!(
            "free VRAM {} MB < required {} MB (no --llm-unload-url; proceeding)",
            v.free_mb, min_mb
        ));
        return;
    }
    log(&format!(
        "free VRAM {} MB < required {} MB; asking llama-swap to unload ({})",
        v.free_mb, min_mb, cfg.llm_unload_url
    ));
    match http_request("POST", &cfg.llm_unload_url, Duration::from_secs(20)) {
        Some(resp) => {
            let status_line = resp.lines().next().unwrap_or("").to_string();
            log(&format!("llama-swap unload response: {status_line}"));
            if status_line.contains(" 2") {
                sh.counts.lock().unwrap().llm_unloads += 1;
            }
        }
        None => log("llama-swap unload request failed"),
    }
    let deadline = Instant::now() + cfg.vram_wait;
    let mut last = v.free_mb;
    while Instant::now() < deadline {
        thread::sleep(Duration::from_secs(2));
        if let Some(v) = read_vram(&cfg.vram_tool) {
            last = v.free_mb;
            *sh.vram.lock().unwrap() = Some(v);
            if last >= min_mb {
                log(&format!("VRAM freed: {last} MB available"));
                return;
            }
        }
    }
    log(&format!(
        "VRAM still low ({} MB < {} MB) after unload; continuing, SD will be slower",
        last, min_mb
    ));
}

fn ensure_running(sh: &Shared, cfg: &Cfg) -> Result<(), String> {
    if sh.server_up() {
        return Ok(());
    }

    if !sh
        .starting
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
    {
        // Another connection is starting the server; wait for it.
        let deadline = Instant::now() + cfg.ready_timeout + Duration::from_secs(5);
        loop {
            if sh.server_up() {
                return Ok(());
            }
            if SHUTDOWN.load(Ordering::SeqCst) || !sh.starting.load(Ordering::SeqCst) {
                return Err("sd-server failed to start".into());
            }
            if Instant::now() > deadline {
                return Err("timed out waiting for sd-server to start".into());
            }
            thread::sleep(Duration::from_millis(250));
        }
    }

    let res = spawn_and_wait(sh, cfg);
    sh.starting.store(false, Ordering::SeqCst);
    res
}

fn spawn_and_wait(sh: &Shared, cfg: &Cfg) -> Result<(), String> {
    sh.ready.store(false, Ordering::SeqCst);
    // Make sure the GPU has room before the model load starts.
    ensure_vram(sh, cfg);
    log(&format!(
        "spawning sd-server: {} (ready timeout {} s)",
        cfg.cmd.join(" "),
        cfg.ready_timeout.as_secs()
    ));
    let child = Command::new(&cfg.cmd[0])
        .args(&cfg.cmd[1..])
        .spawn()
        .map_err(|e| format!("failed to spawn sd-server: {e}"))?;
    let pid = child.id();
    sh.spawned_at_ms.store(now_ms(), Ordering::SeqCst);
    {
        let mut srv = sh.server.lock().unwrap();
        srv.child = Some(child);
    }
    let _ = std::fs::write(PIDFILE, pid.to_string());
    sh.counts.lock().unwrap().spawns += 1;

    let deadline = Instant::now() + cfg.ready_timeout;
    loop {
        if probe_ready(&cfg.upstream) {
            sh.ready.store(true, Ordering::SeqCst);
            sh.ready_at_ms.store(now_ms(), Ordering::SeqCst);
            log("sd-server is ready");
            return Ok(());
        }
        if SHUTDOWN.load(Ordering::SeqCst) || Instant::now() > deadline {
            break;
        }
        thread::sleep(Duration::from_secs(1));
    }
    kill_child(sh);
    Err("sd-server did not become ready in time".into())
}

// ---------------------------------------------------------------------------
// Connection handling (port 8084)
// ---------------------------------------------------------------------------

/// Read up to 64 KiB (or the end of the headers) so we can record *who* is
/// requesting (nginx sets X-Forwarded-For / X-Real-IP) before relaying.
fn peek_headers(client: &mut TcpStream, peer: String) -> (Vec<u8>, Option<(String, String, String)>) {
    let mut buf = Vec::with_capacity(8192);
    let mut chunk = [0u8; 8192];
    let _ = client.set_read_timeout(Some(Duration::from_secs(10)));
    while buf.len() < 65_536 {
        match client.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.len() >= 4 && buf.windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let text = String::from_utf8_lossy(&buf);
    let parsed = parse_request_head(&text);
    (
        buf,
        parsed.map(|(m, p, r)| (m, p, if r.is_empty() { peer } else { r })),
    )
}

fn parse_request_head(text: &str) -> Option<(String, String, String)> {
    let mut lines = text.split("\r\n");
    let request_line = lines.next()?.trim().to_string();
    let mut words = request_line.split_whitespace();
    let method = words.next().unwrap_or("GET").to_string();
    let path = words.next().unwrap_or("/").to_string();
    let mut forwarded = String::new();
    let mut real_ip = String::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            match k.trim().to_ascii_lowercase().as_str() {
                "x-forwarded-for" => {
                    let first = v.trim().split(',').next().unwrap_or("").trim().to_string();
                    if !first.is_empty() {
                        forwarded = first;
                    }
                }
                "x-real-ip" => real_ip = v.trim().to_string(),
                _ => {}
            }
        }
    }
    let remote = if forwarded.is_empty() { real_ip } else { forwarded };
    Some((method, path, remote))
}

fn send_503(mut s: &TcpStream) {
    let resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    let _ = s.write_all(resp.as_bytes());
}

/// Relay one connection between `client` and the upstream sd-server.
/// `prefix` holds request bytes already read by `peek_headers`.
fn relay_with_prefix(mut client: TcpStream, prefix: Vec<u8>, upstream: &str) {
    let mut up = match TcpStream::connect(upstream) {
        Ok(u) => u,
        Err(e) => {
            log(&format!("upstream connect failed: {e}"));
            send_503(&client);
            return;
        }
    };
    if !prefix.is_empty() && up.write_all(&prefix).is_err() {
        return;
    }
    let mut c1 = match client.try_clone() {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut u1 = match up.try_clone() {
        Ok(u) => u,
        Err(_) => return,
    };
    // client -> upstream (rest of the request). Never half-close upstream
    // here: sd-server (stable-diffusion.cpp) treats a client FIN as "client
    // disconnected" and, after a long generation, closes the connection
    // WITHOUT sending the response (nginx then sees a 502 "upstream
    // prematurely closed connection" at the moment the image finished).
    // `up` is closed when this function returns, after the response was
    // relayed, so the FIN reaches sd-server only when it is harmless.
    let t = thread::spawn(move || {
        let _ = std::io::copy(&mut c1, &mut u1);
    });
    // upstream -> client (response)
    let _ = std::io::copy(&mut up, &mut client);
    // Shut down both directions: the Write half tells nginx the response is
    // complete, and the Read half unblocks the request-copy thread above on
    // fast responses (it would otherwise sit in its 10 s read timeout).
    let _ = client.shutdown(std::net::Shutdown::Both);
    let _ = t.join();
}

// ---------------------------------------------------------------------------
// Status endpoint (port 8086)
// ---------------------------------------------------------------------------

const STATUS_HTML: &str = r##"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>sd-gate</title>
<style>
:root { --bg:#0f1115; --panel:#161a22; --border:#2a3140; --text:#d6dae3; --muted:#8b93a3; --ok:#4ade80; --warn:#fbbf24; --err:#f87171; }
* { box-sizing: border-box; }
body { margin:0; padding:24px; background:var(--bg); color:var(--text); font-family:system-ui,-apple-system,sans-serif; font-size:14px; max-width:860px; }
h1 { font-size:18px; margin:0 0 4px; }
.sub { color:var(--muted); font-size:12px; margin:0 0 18px; }
.badge { display:inline-block; padding:3px 12px; border-radius:12px; font-size:13px; border:1px solid var(--border); }
.badge.ready { color:var(--ok); border-color:var(--ok)55; }
.badge.starting, .badge.stopping { color:var(--warn); border-color:var(--warn)55; }
.badge.idle { color:var(--muted); }
table { width:100%; border-collapse:collapse; margin-top:8px; }
th, td { text-align:left; padding:5px 8px; border-bottom:1px solid var(--border); font-size:13px; }
th { color:var(--muted); font-weight:500; font-size:12px; }
.kv { margin:10px 0; color:var(--muted); font-size:13px; }
.kv b { color:var(--text); font-weight:600; }
code { color:var(--text); }
</style>
</head>
<body>
<h1>sd-gate</h1>
<p class="sub">on-demand sd-server launcher &middot; auto-refreshes every 2 s &middot; JSON at <code>/sd-status/status</code></p>
<p>state: <span id="state" class="badge">…</span></p>
<p class="kv">sd-server: <b id="server">…</b></p>
<p class="kv">idle unload: <b id="until">…</b> &nbsp;·&nbsp; last activity: <b id="last">…</b></p>
<p class="kv">VRAM: <b id="vram">…</b> (min free to avoid LLM unload: <b id="minvram">…</b> MB)</p>
<p class="kv">active clients (why the model is running):</p>
<table id="clients">
<tr><th>remote</th><th>request</th><th>age</th><th>phase</th></tr>
</table>
<p class="kv">counts: <b id="counts">…</b></p>
<script>
function esc(s) { const d = document.createElement("div"); d.textContent = s; return d.innerHTML; }
async function refresh() {
  try {
    const r = await fetch("status", { cache: "no-store" });
    const j = await r.json();
    const st = document.getElementById("state");
    st.textContent = j.state;
    st.className = "badge " + j.state;
    const s = j.sd_server || {};
    document.getElementById("server").textContent = s.ready
      ? ("pid " + s.pid + ", up since " + (s.ready_at_ms ? new Date(s.ready_at_ms).toUTCString() : "?"))
      : (s.pid ? "pid " + s.pid + " (starting)" : "not running");
    const i = j.idle || {};
    document.getElementById("until").textContent = (j.state === "ready" && i.seconds_until_unload !== null)
      ? (i.seconds_until_unload + " s (timeout " + i.timeout_secs + " s)")
      : (j.state === "ready" ? "held by active client(s)" : "n/a");
    document.getElementById("last").textContent = i.last_activity || "?";
    const v = j.vram;
    document.getElementById("vram").textContent = v
      ? (Math.round(v.free_mb / 1024 * 10) / 10 + " / " + Math.round(v.total_mb / 1024 * 10) / 10 + " GiB free/total")
      : "unknown";
    document.getElementById("minvram").textContent = j.min_vram_mb;
    const t = document.getElementById("clients");
    t.querySelectorAll("tr:not(:first-child)").forEach(r => r.remove());
    for (const c of j.clients || []) {
      const tr = document.createElement("tr");
      for (const x of [c.remote, c.method + " " + c.path, c.age_secs + " s", c.phase]) {
        const td = document.createElement("td");
        td.innerHTML = esc(x);
        tr.appendChild(td);
      }
      t.appendChild(tr);
    }
    const n = j.counts || {};
    document.getElementById("counts").textContent =
      n.requests + " requests · " + n.spawns + " spawns · " + n.idle_kills + " idle kills · " +
      n.llm_unloads + " LLM unloads · " + n.spawn_failures + " failures";
  } catch (e) {
    const st = document.getElementById("state");
    st.textContent = "offline: " + e.message;
    st.className = "badge";
  }
}
setInterval(refresh, 2000);
refresh();
</script>
</body>
</html>"##;

fn status_json(sh: &Shared, cfg: &Cfg) -> String {
    let pid = {
        let srv = sh.server.lock().unwrap();
        srv.child.as_ref().map(|c| c.id())
    };
    let state = sh.state();
    let ready = sh.ready.load(Ordering::SeqCst);
    let clients_n = sh.clients.load(Ordering::SeqCst);
    let last = sh.last_active_ms.load(Ordering::SeqCst);
    let timeout_s = cfg.idle.as_secs();
    let until = if state == "ready" && clients_n == 0 {
        let elapsed_s = (now_ms().saturating_sub(last)) / 1000;
        Some(timeout_s.saturating_sub(elapsed_s.max(0) as u64))
    } else {
        None
    };
    let until_json = match until {
        Some(u) => u.to_string(),
        None => "null".to_string(),
    };
    let pid_json = match pid {
        Some(p) => p.to_string(),
        None => "null".to_string(),
    };
    let spawned = sh.spawned_at_ms.load(Ordering::SeqCst);
    let ready_at = sh.ready_at_ms.load(Ordering::SeqCst);
    let clients_json = {
        let list = sh.client_list.lock().unwrap();
        let now = now_ms();
        list.iter()
            .map(|c| {
                let age = (now.saturating_sub(c.since_ms) / 1000).max(0);
                let phase = if c.relaying.load(Ordering::SeqCst) {
                    "relaying"
                } else {
                    "waiting-for-start"
                };
                format!(
                    "{{\"remote\":\"{}\",\"method\":\"{}\",\"path\":\"{}\",\"age_secs\":{age},\"phase\":\"{phase}\"}}",
                    json_escape(&c.remote),
                    json_escape(&c.method),
                    json_escape(&c.path)
                )
            })
            .collect::<Vec<_>>()
            .join(",")
    };
    let vram_json = match sh.vram.lock().unwrap().as_ref() {
        Some(v) => format!(
            "{{\"free_mb\":{},\"total_mb\":{},\"checked_ms\":{}}}",
            v.free_mb, v.total_mb, v.checked_ms
        ),
        None => "null".to_string(),
    };
    let c = sh.counts.lock().unwrap();
    format!(
        "{{\"state\":\"{state}\",\"sd_server\":{{\"pid\":{pid_json},\"ready\":{ready},\"spawned_at_ms\":{spawned},\"ready_at_ms\":{ready_at}}},\"idle\":{{\"timeout_secs\":{timeout_s},\"seconds_until_unload\":{until_json},\"last_activity_ms\":{last},\"last_activity\":\"{}\"}},\"min_vram_mb\":{},\"vram\":{vram_json},\"clients\":[{clients_json}],\"counts\":{{\"requests\":{},\"spawns\":{},\"idle_kills\":{},\"llm_unloads\":{},\"spawn_failures\":{}}}}}",
        human_time(last),
        (cfg.min_vram_gib * 1024.0) as i64,
        c.requests,
        c.spawns,
        c.idle_kills,
        c.llm_unloads,
        c.spawn_failures
    )
}

fn serve_status(listener: TcpListener, sh: Arc<Shared>, cfg: Arc<Cfg>) {
    for stream in listener.incoming() {
        let Ok(mut s) = stream else {
            continue;
        };
        let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
        let _ = s.set_write_timeout(Some(Duration::from_secs(5)));
        let mut buf = Vec::with_capacity(2048);
        let mut one = [0u8; 1024];
        while buf.len() < 4096 {
            match s.read(&mut one) {
                Ok(0) => break,
                Ok(n) => {
                    buf.extend_from_slice(&one[..n]);
                    if buf.len() >= 4 && buf.windows(4).any(|w| w == b"\r\n\r\n") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let text = String::from_utf8_lossy(&buf);
        let path = text
            .lines()
            .next()
            .and_then(|l| l.split_whitespace().nth(1))
            .unwrap_or("/");
        // Keep the VRAM reading fresh without hammering amd-smi.
        {
            let stale = match sh.vram.lock().unwrap().as_ref() {
                Some(v) => now_ms() - v.checked_ms > 5000,
                None => true,
            };
            if stale {
                if let Some(v) = read_vram(&cfg.vram_tool) {
                    *sh.vram.lock().unwrap() = Some(v);
                }
            }
        }
        let (status, ctype, body) = match path {
            "/status" => ("200 OK", "application/json", status_json(&sh, &cfg)),
            "/" => ("200 OK", "text/html; charset=utf-8", STATUS_HTML.to_string()),
            _ => ("404 Not Found", "text/plain", "not found".to_string()),
        };
        let resp = format!(
            "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = s.write_all(resp.as_bytes());
    }
}

// ---------------------------------------------------------------------------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut listen = "127.0.0.1:8084";
    let mut status_listen = "127.0.0.1:8086";
    let mut upstream = "127.0.0.1:8085";
    let mut idle_secs: u64 = 120;
    let mut ready_secs: u64 = 180;
    let mut vram_tool = "amd-smi";
    let mut min_vram_gib: f64 = 10.0;
    let mut llm_unload_url = "http://127.0.0.1:8081/api/models/unload";
    let mut vram_wait_secs: u64 = 90;
    let mut cmd: Option<Vec<String>> = None;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--listen" => {
                i += 1;
                listen = args.get(i).expect("--listen needs a value");
            }
            "--status-listen" => {
                i += 1;
                status_listen = args.get(i).expect("--status-listen needs a value");
            }
            "--upstream" => {
                i += 1;
                upstream = args.get(i).expect("--upstream needs a value");
            }
            "--idle" => {
                i += 1;
                idle_secs = args
                    .get(i)
                    .and_then(|v| v.parse().ok())
                    .expect("--idle needs a number");
            }
            "--ready-timeout" => {
                i += 1;
                ready_secs = args
                    .get(i)
                    .and_then(|v| v.parse().ok())
                    .expect("--ready-timeout needs a number");
            }
            "--vram-tool" => {
                i += 1;
                vram_tool = args.get(i).expect("--vram-tool needs a value");
            }
            "--min-vram-gib" => {
                i += 1;
                min_vram_gib = args
                    .get(i)
                    .and_then(|v| v.parse().ok())
                    .expect("--min-vram-gib needs a number");
            }
            "--llm-unload-url" => {
                i += 1;
                llm_unload_url = args.get(i).expect("--llm-unload-url needs a value");
            }
            "--vram-wait-secs" => {
                i += 1;
                vram_wait_secs = args
                    .get(i)
                    .and_then(|v| v.parse().ok())
                    .expect("--vram-wait-secs needs a number");
            }
            "--" => {
                cmd = Some(args[i + 1..].to_vec());
                break;
            }
            other => {
                eprintln!("unknown option: {other}");
                eprintln!("usage: sd-gate [--listen ADDR] [--status-listen ADDR] [--upstream ADDR] [--idle SECS] [--ready-timeout SECS] [--vram-tool PATH] [--min-vram-gib N] [--llm-unload-url URL] [--vram-wait-secs N] -- <sd-server command>");
                std::process::exit(2);
            }
        }
        i += 1;
    }
    let cmd = match cmd {
        Some(c) if !c.is_empty() => c,
        _ => {
            eprintln!("missing child command after --");
            std::process::exit(2);
        }
    };

    let cfg = Arc::new(Cfg {
        listen: listen.to_string(),
        status_listen: status_listen.to_string(),
        upstream: upstream.to_string(),
        idle: Duration::from_secs(idle_secs),
        ready_timeout: Duration::from_secs(ready_secs),
        vram_tool: vram_tool.to_string(),
        min_vram_gib,
        llm_unload_url: llm_unload_url.to_string(),
        vram_wait: Duration::from_secs(vram_wait_secs),
        cmd,
    });

    let handler = on_signal as *const () as usize;
    unsafe {
        signal(SIGTERM, handler);
        signal(SIGINT, handler);
    }

    let listener = match TcpListener::bind(&cfg.listen) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("failed to bind {}: {e}", cfg.listen);
            std::process::exit(1);
        }
    };
    log(&format!(
        "listening on {} -> {} (idle timeout {} s)",
        cfg.listen,
        cfg.upstream,
        cfg.idle.as_secs()
    ));

    let sh = Arc::new(Shared {
        server: Mutex::new(Server { child: None }),
        starting: AtomicBool::new(false),
        ready: AtomicBool::new(false),
        adopted: AtomicBool::new(false),
        clients: AtomicUsize::new(0),
        client_list: Mutex::new(Vec::new()),
        last_active_ms: AtomicI64::new(now_ms()),
        spawned_at_ms: AtomicI64::new(0),
        ready_at_ms: AtomicI64::new(0),
        vram: Mutex::new(None),
        counts: Mutex::new(Counts {
            requests: 0,
            spawns: 0,
            idle_kills: 0,
            llm_unloads: 0,
            spawn_failures: 0,
        }),
    });

    // If a previous (crashed) gate left sd-server running, adopt it instead
    // of trying to spawn a second one that can't bind the upstream port.
    if probe_ready(&cfg.upstream) {
        log(&format!(
            "sd-server already serving on {}; adopting it (it will not idle-unload until it exits)",
            cfg.upstream
        ));
        sh.adopted.store(true, Ordering::SeqCst);
        sh.ready.store(true, Ordering::SeqCst);
    }

    // Status listener (HTML at /, JSON at /status). Never spawns the server.
    if !cfg.status_listen.is_empty() {
        match TcpListener::bind(&cfg.status_listen) {
            Ok(sl) => {
                log(&format!("status endpoint on {}", cfg.status_listen));
                let (sh2, cfg2) = (sh.clone(), cfg.clone());
                thread::Builder::new()
                    .name("status".into())
                    .spawn(move || serve_status(sl, sh2, cfg2))
                    .expect("spawn status thread");
            }
            Err(e) => eprintln!("failed to bind status listener {}: {e}", cfg.status_listen),
        }
    }

    let (tx, rx) = mpsc::channel::<TcpStream>();
    {
        thread::Builder::new()
            .name("accept".into())
            .spawn(move || {
                for stream in listener.incoming() {
                    match stream {
                        Ok(s) => {
                            if tx.send(s).is_err() {
                                break;
                            }
                        }
                        Err(e) => log(&format!("accept error: {e}")),
                    }
                }
            })
            .expect("spawn accept thread");
    }

    loop {
        match rx.recv_timeout(Duration::from_millis(500)) {
            Ok(client) => {
                sh.clients.fetch_add(1, Ordering::SeqCst);
                sh.last_active_ms.store(now_ms(), Ordering::SeqCst);
                sh.counts.lock().unwrap().requests += 1;
                let (sh2, cfg2) = (sh.clone(), cfg.clone());
                thread::Builder::new()
                    .name("conn".into())
                    .spawn(move || {
                        let peer = client
                            .peer_addr()
                            .map(|a| a.to_string())
                            .unwrap_or_else(|_| "?".into());
                        let mut client = client;
                        let (prefix, meta) = peek_headers(&mut client, peer);
                        let (method, path, remote) =
                            meta.unwrap_or_else(|| ("?".into(), "?".into(), "?".into()));
                        let info = Arc::new(ClientInfo {
                            remote,
                            method,
                            path,
                            since_ms: now_ms(),
                            relaying: AtomicBool::new(false),
                        });
                        sh2.client_list.lock().unwrap().push(info.clone());
                        match ensure_running(&sh2, &cfg2) {
                            Ok(()) => {
                                info.relaying.store(true, Ordering::SeqCst);
                                relay_with_prefix(client, prefix, &cfg2.upstream);
                            }
                            Err(e) => {
                                sh2.counts.lock().unwrap().spawn_failures += 1;
                                log(&format!("request rejected: {e}"));
                                send_503(&client);
                            }
                        }
                        sh2.client_list
                            .lock()
                            .unwrap()
                            .retain(|c| !Arc::ptr_eq(c, &info));
                        sh2.clients.fetch_sub(1, Ordering::SeqCst);
                    })
                    .expect("spawn conn thread");
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }

        // Reaper: reap crashed children, unload (kill) after idle.
        if sh.clients.load(Ordering::SeqCst) == 0 {
            let mut srv = sh.server.lock().unwrap();
            if let Some(c) = srv.child.as_mut() {
                match c.try_wait() {
                    Ok(Some(status)) => {
                        log(&format!("sd-server exited on its own ({status})"));
                        srv.child = None;
                        sh.ready.store(false, Ordering::SeqCst);
                        let _ = std::fs::remove_file(PIDFILE);
                    }
                    Ok(None) => {
                        let idle_ms = now_ms() - sh.last_active_ms.load(Ordering::SeqCst);
                        if idle_ms >= cfg.idle.as_millis() as i64 {
                            log(&format!(
                                "idle for {} s; killing sd-server to free VRAM",
                                cfg.idle.as_secs()
                            ));
                            let _ = c.kill();
                            let _ = c.wait();
                            srv.child = None;
                            sh.ready.store(false, Ordering::SeqCst);
                            let _ = std::fs::remove_file(PIDFILE);
                            sh.counts.lock().unwrap().idle_kills += 1;
                        }
                    }
                    Err(e) => log(&format!("try_wait failed: {e}")),
                }
            }
        }

        if SHUTDOWN.load(Ordering::SeqCst) {
            break;
        }
    }

    // Shutdown: kill the child so it is not orphaned (its VRAM would stay
    // loaded). The unit's ExecStop is a safety net for SIGKILL stops.
    kill_child(&sh);
    log("bye");
}
