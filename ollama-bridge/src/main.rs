//! ollama-bridge: exposes an Ollama-compatible API (`/api/*`) in front of an
//! OpenAI-compatible llama.cpp endpoint (typically llama-swap).
//!
//! This lets Ollama-only clients (e.g. Recallium's Ollama LLM provider) use a
//! llama.cpp instance that is managed by llama-swap. Zero dependencies: Rust
//! stdlib only, mirroring `llama-log-viewer` in this repo.
//!
//! Usage:
//!   ollama-bridge [--listen 0.0.0.0:11434] [--upstream http://127.0.0.1:8081/upstream/vulkan/v1] [--model vulkan]
//!
//! Implemented endpoints:
//!   GET  /api/version
//!   GET  /api/tags          (lists models from the upstream /models)
//!   GET  /api/ps            (always empty; llama-swap manages the servers)
//!   POST /api/chat          (stream + non-stream)
//!   POST /api/generate      (stream + non-stream)

mod json;

use json::Json;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::thread;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const MAX_REQUEST_BODY: usize = 32 * 1024 * 1024; // 32 MiB
const MAX_LINE: usize = 16 * 1024 * 1024; // 16 MiB per SSE/NDJSON line

struct Config {
    listen: String,
    upstream_host: String,  // host:port of the upstream server
    upstream_prefix: String, // path prefix (e.g. /upstream/vulkan/v1) or ""
    model: String,          // model name used when the request does not specify one
    max_tokens: i64,        // default completion length cap when the client does not set one
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Format a unix timestamp as RFC3339 UTC with microseconds, e.g.
/// `2026-08-14T12:34:56.123456Z` (Ollama's `created_at` style).
fn rfc3339(secs: i64, micros: u32) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (h, mi, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    // Civil date from days since epoch (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:06}Z",
        y, m, d, h, mi, s, micros
    )
}

// ---------------------------------------------------------------------------
// Outgoing HTTP responses
// ---------------------------------------------------------------------------

fn write_simple(stream: &mut TcpStream, status: &str, ctype: &str, body: &[u8]) {
    let header = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        status,
        ctype,
        body.len()
    );
    let _ = stream.write_all(header.as_bytes());
    let _ = stream.write_all(body);
    let _ = stream.flush();
}

fn write_json(stream: &mut TcpStream, status: u16, obj: &Json) {
    let body = obj.to_string();
    let status_line = match status {
        200 => "200 OK",
        400 => "400 Bad Request",
        404 => "404 Not Found",
        413 => "413 Payload Too Large",
        502 => "502 Bad Gateway",
        503 => "503 Service Unavailable",
        _ => "500 Internal Server Error",
    };
    write_simple(stream, status_line, "application/json; charset=utf-8", body.as_bytes());
}

/// Write one chunk of a chunked response.
fn write_chunk(stream: &mut TcpStream, data: &[u8]) {
    let _ = stream.write_all(format!("{:x}\r\n", data.len()).as_bytes());
    let _ = stream.write_all(data);
    let _ = stream.write_all(b"\r\n");
}

fn write_chunk_end(stream: &mut TcpStream) {
    let _ = stream.write_all(b"0\r\n\r\n");
    let _ = stream.flush();
}

// ---------------------------------------------------------------------------
// Minimal HTTP client (stdlib only)
// ---------------------------------------------------------------------------

enum BodyReader {
    ContentLength(BufReader<TcpStream>, u64),
    Chunked {
        inner: BufReader<TcpStream>,
        remaining: u64,
        eof: bool,
    },
    Empty,
}

impl Read for BodyReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            BodyReader::ContentLength(reader, remaining) => {
                if *remaining == 0 {
                    return Ok(0);
                }
                let want = buf.len().min(*remaining as usize);
                let n = reader.read(&mut buf[..want])?;
                *remaining -= n as u64;
                Ok(n)
            }
            BodyReader::Chunked { inner, remaining, eof } => {
                if *eof {
                    return Ok(0);
                }
                if *remaining == 0 {
                    // Read the next chunk-size line.
                    let mut size_line = Vec::new();
                    let mut byte = [0u8; 1];
                    loop {
                        if inner.read(&mut byte)? == 0 {
                            *eof = true;
                            return Ok(0);
                        }
                        size_line.push(byte[0]);
                        if byte[0] == b'\n' {
                            break;
                        }
                        if size_line.len() > 64 {
                            return Err(std::io::Error::new(
                                std::io::ErrorKind::InvalidData,
                                "chunk size line too long",
                            ));
                        }
                    }
                    let size_str = String::from_utf8_lossy(&size_line);
                    let size_hex: String = size_str
                        .trim()
                        .split(';')
                        .next()
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    let size = u64::from_str_radix(&size_hex, 16).map_err(|_| {
                        std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            format!("bad chunk size: {size_str:?}"),
                        )
                    })?;
                    if size == 0 {
                        // Consume trailers until the terminating blank line.
                        let mut line = Vec::new();
                        let mut byte = [0u8; 1];
                        loop {
                            if inner.read(&mut byte)? == 0 {
                                break;
                            }
                            line.push(byte[0]);
                            if byte[0] == b'\n' {
                                if line == b"\r\n" || line == b"\n" {
                                    break;
                                }
                                line.clear();
                            }
                            if line.len() > 64 * 1024 {
                                break;
                            }
                        }
                        *eof = true;
                        return Ok(0);
                    }
                    *remaining = size;
                }
                let want = buf.len().min(*remaining as usize);
                let n = inner.read(&mut buf[..want])?;
                *remaining -= n as u64;
                if *remaining == 0 {
                    // Consume the CRLF that terminates the chunk data (tolerate
                    // servers that omit it).
                    let mut crlf = [0u8; 2];
                    let mut got = 0;
                    while got < 2 {
                        match inner.read(&mut crlf[got..]) {
                            Ok(0) => break,
                            Ok(k) => got += k,
                            Err(e) => return Err(e),
                        }
                    }
                }
                Ok(n)
            }
            BodyReader::Empty => Ok(0),
        }
    }
}

struct UpstreamResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: BodyReader,
}

/// Read the status line + headers of an HTTP response; returns a reader over
/// the (possibly de-chunked) body.
fn read_response(reader: BufReader<TcpStream>) -> Result<UpstreamResponse, String> {
    let mut reader = reader;
    let mut status_line = String::new();
    reader
        .read_line(&mut status_line)
        .map_err(|e| format!("read status line: {e}"))?;
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let mut headers: Vec<(String, String)> = Vec::new();
    loop {
        let mut line = String::new();
        let n = reader
            .read_line(&mut line)
            .map_err(|e| format!("read header: {e}"))?;
        if n == 0 {
            return Err("unexpected EOF in headers".into());
        }
        let trimmed = line.trim_end();
        if trimmed.is_empty() {
            break;
        }
        if let Some((k, v)) = trimmed.split_once(':') {
            headers.push((k.trim().to_lowercase(), v.trim().to_string()));
        }
    }
    let header = |name: &str| -> Option<String> {
        headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.clone())
    };
    let transfer = header("transfer-encoding").unwrap_or_default().to_lowercase();
    let content_length = header("content-length")
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0);

    let body = if transfer.contains("chunked") {
        BodyReader::Chunked {
            inner: reader,
            remaining: 0,
            eof: false,
        }
    } else if content_length > 0 {
        BodyReader::ContentLength(reader, content_length)
    } else {
        BodyReader::Empty
    };
    Ok(UpstreamResponse { status, headers, body })
}

fn connect_upstream(cfg: &Config) -> Result<TcpStream, String> {
    let stream = TcpStream::connect(&cfg.upstream_host)
        .map_err(|e| format!("connect upstream {}: {e}", cfg.upstream_host))?;
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(300)))
        .ok();
    stream
        .set_write_timeout(Some(std::time::Duration::from_secs(60)))
        .ok();
    Ok(stream)
}

fn host_of(cfg: &Config) -> String {
    cfg.upstream_host.clone()
}

fn send_upstream(
    cfg: &Config,
    method: &str,
    path: &str,
    body: Option<&Json>,
    accept: &str,
) -> Result<UpstreamResponse, String> {
    let stream = connect_upstream(cfg)?;
    let full_path = format!("{}{}", cfg.upstream_prefix, path);
    let body_bytes = body.map(|b| b.to_string()).unwrap_or_default();
    let req = format!(
        "{} {} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccept: {}\r\nConnection: close\r\n\r\n{}",
        method,
        full_path,
        host_of(cfg),
        body_bytes.len(),
        accept,
        body_bytes
    );
    let mut stream = stream;
    stream
        .write_all(req.as_bytes())
        .map_err(|e| format!("send upstream: {e}"))?;
    stream.flush().ok();
    read_response(BufReader::new(stream))
}

/// Full round-trip: request + buffered response body, parsed as JSON when
/// possible. Returns (status, Json).
fn upstream_json(
    cfg: &Config,
    method: &str,
    path: &str,
    body: Option<&Json>,
) -> Result<(u16, Json), String> {
    let mut resp = send_upstream(cfg, method, path, body, "application/json, text/event-stream")?;
    let mut bytes = Vec::new();
    resp.body
        .read_to_end(&mut bytes)
        .map_err(|e| format!("read upstream body: {e}"))?;
    let text = String::from_utf8_lossy(&bytes);
    match Json::parse(&text) {
        Ok(v) => Ok((resp.status, v)),
        Err(_) => Ok((resp.status, Json::obj(vec![("raw".into(), Json::str(text.into_owned()))]))),
    }
}

/// Open a streaming upstream connection; returns (status, body reader).
fn upstream_stream(
    cfg: &Config,
    method: &str,
    path: &str,
    body: &Json,
) -> Result<(u16, BodyReader), String> {
    let resp = send_upstream(cfg, method, path, Some(body), "text/event-stream")?;
    Ok((resp.status, resp.body))
}

// ---------------------------------------------------------------------------
// Request parsing (server side)
// ---------------------------------------------------------------------------

struct Request {
    method: String,
    path: String,
    body: Vec<u8>,
}

fn read_request(reader: &mut BufReader<TcpStream>) -> Result<Request, String> {
    let mut request_line = String::new();
    let n = reader
        .read_line(&mut request_line)
        .map_err(|e| format!("read request line: {e}"))?;
    if n == 0 {
        return Err("connection closed".into());
    }
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let target = parts.next().unwrap_or("/").to_string();
    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        let n = reader
            .read_line(&mut line)
            .map_err(|e| format!("read header: {e}"))?;
        if n == 0 {
            break;
        }
        let trimmed = line.trim_end();
        if trimmed.is_empty() {
            break;
        }
        if let Some((k, v)) = trimmed.split_once(':') {
            if k.trim().eq_ignore_ascii_case("content-length") {
                content_length = v.trim().parse().unwrap_or(0);
            }
        }
    }
    if content_length > MAX_REQUEST_BODY {
        return Err("body too large".into());
    }
    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        reader
            .read_exact(&mut body)
            .map_err(|e| format!("read body: {e}"))?;
    }
    let path = target.split('?').next().unwrap_or(&target).to_string();
    Ok(Request { method, path, body })
}

fn parse_body(raw: &[u8]) -> Result<Json, String> {
    let text = String::from_utf8_lossy(raw);
    Json::parse(&text).map_err(|e| format!("invalid JSON body: {e}"))
}

// ---------------------------------------------------------------------------
// Ollama -> OpenAI translation
// ---------------------------------------------------------------------------

/// Build an OpenAI `/v1/chat/completions` request body from an Ollama
/// `/api/chat` request body.
fn build_openai_chat(cfg: &Config, ollama: &Json) -> Result<Json, String> {
    let model = ollama
        .get("model")
        .and_then(|m| m.as_str())
        .unwrap_or(&cfg.model)
        .to_string();

    let mut messages: Vec<Json> = Vec::new();
    if let Some(sys) = ollama.get("system").and_then(|s| s.as_str()) {
        messages.push(Json::obj(vec![
            ("role".into(), Json::str("system")),
            ("content".into(), Json::str(sys)),
        ]));
    }
    match ollama.get("messages") {
        Some(Json::Arr(items)) => messages.extend(items.iter().cloned()),
        Some(other) => {
            return Err(format!("`messages` must be an array, got {}", other.to_string()))
        }
        None => {
            if let Some(prompt) = ollama.get("prompt").and_then(|p| p.as_str()) {
                messages.push(Json::obj(vec![
                    ("role".into(), Json::str("user")),
                    ("content".into(), Json::str(prompt)),
                ]));
            } else {
                return Err("missing `messages` in /api/chat request".into());
            }
        }
    }
    if messages.is_empty() {
        return Err("empty `messages` in /api/chat request".into());
    }

    let mut fields: Vec<(String, Json)> = vec![
        ("model".into(), Json::str(model)),
        ("messages".into(), Json::Arr(messages)),
    ];

    let stream = ollama.get("stream").and_then(|s| s.as_bool()).unwrap_or(false);
    fields.push(("stream".into(), Json::bool(stream)));

    // Map Ollama `options` onto OpenAI-compatible parameters that llama.cpp
    // understands. Unrecognised options are dropped.
    if let Some(opts) = ollama.get("options").and_then(|o| o.as_obj()) {
        let pick = |names: &[&str]| -> Option<&Json> {
            for n in names {
                if let Some(v) = opts.iter().find(|(k, _)| k == n) {
                    return Some(&v.1);
                }
            }
            None
        };
        for (ollama_key, openai_key) in [
            ("temperature", "temperature"),
            ("top_p", "top_p"),
            ("top_k", "top_k"),
            ("seed", "seed"),
            ("repeat_penalty", "repeat_penalty"),
            ("min_p", "min_p"),
            ("presence_penalty", "presence_penalty"),
            ("frequency_penalty", "frequency_penalty"),
            ("stop", "stop"),
        ] {
            if let Some(v) = pick(&[ollama_key]) {
                fields.push((openai_key.to_string(), v.clone()));
            }
        }
        // num_predict -> max_tokens
        if let Some(v) = pick(&["num_predict"]) {
            fields.push(("max_tokens".into(), v.clone()));
        }
    }

    // Default completion cap: without one, reasoning models can generate for
    // minutes (Recallium's clients time out long before that).
    if !fields.iter().any(|(k, _)| k == "max_tokens") {
        fields.push(("max_tokens".into(), Json::num(cfg.max_tokens as f64)));
    }

    // Ollama `format: "json"` -> OpenAI json_object response format.
    if let Some(fmt) = ollama.get("format") {
        if let Some(s) = fmt.as_str() {
            if s.eq_ignore_ascii_case("json") {
                fields.push((
                    "response_format".into(),
                    Json::obj(vec![("type".into(), Json::str("json_object"))]),
                ));
            }
        }
    }

    // Tool definitions pass through (llama.cpp supports OpenAI tool calling).
    if let Some(tools) = ollama.get("tools") {
        fields.push(("tools".into(), tools.clone()));
    }

    Ok(Json::obj(fields))
}

/// Build an OpenAI `/v1/completions` request body from an Ollama
/// `/api/generate` request body.
fn build_openai_completions(cfg: &Config, ollama: &Json) -> Result<Json, String> {
    let model = ollama
        .get("model")
        .and_then(|m| m.as_str())
        .unwrap_or(&cfg.model)
        .to_string();
    let prompt = ollama
        .get("prompt")
        .and_then(|p| p.as_str())
        .ok_or_else(|| "missing `prompt` in /api/generate request".to_string())?;
    let stream = ollama.get("stream").and_then(|s| s.as_bool()).unwrap_or(false);
    let mut fields: Vec<(String, Json)> = vec![
        ("model".into(), Json::str(model)),
        ("prompt".into(), Json::str(prompt)),
        ("stream".into(), Json::bool(stream)),
    ];
    if let Some(opts) = ollama.get("options").and_then(|o| o.as_obj()) {
        let pick = |names: &[&str]| -> Option<&Json> {
            for n in names {
                if let Some(v) = opts.iter().find(|(k, _)| k == n) {
                    return Some(&v.1);
                }
            }
            None
        };
        for key in [
            "temperature",
            "top_p",
            "top_k",
            "seed",
            "repeat_penalty",
            "min_p",
            "presence_penalty",
            "frequency_penalty",
            "stop",
        ] {
            if let Some(v) = pick(&[key]) {
                fields.push((key.to_string(), v.clone()));
            }
        }
        if let Some(v) = pick(&["num_predict"]) {
            fields.push(("max_tokens".into(), v.clone()));
        }
    }
    if !fields.iter().any(|(k, _)| k == "max_tokens") {
        fields.push(("max_tokens".into(), Json::num(cfg.max_tokens as f64)));
    }
    Ok(Json::obj(fields))
}

/// Convert a non-streaming OpenAI chat completion into an Ollama chat response.
fn openai_chat_to_ollama(model: &str, upstream: &Json) -> Json {
    let created = upstream
        .get("created")
        .and_then(|c| c.as_i64())
        .unwrap_or_else(now_unix);
    let choice = upstream
        .get("choices")
        .and_then(|c| c.as_arr())
        .and_then(|a| a.first());
    let message = choice.and_then(|c| c.get("message"));
    let content = message
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_str())
        .unwrap_or("");
    let role = message
        .and_then(|m| m.get("role"))
        .and_then(|r| r.as_str())
        .unwrap_or("assistant");
    let finish = choice
        .and_then(|c| c.get("finish_reason"))
        .and_then(|f| f.as_str())
        .unwrap_or("stop");
    let usage = upstream.get("usage");
    let prompt_tokens = usage
        .and_then(|u| u.get("prompt_tokens"))
        .and_then(|t| t.as_i64())
        .unwrap_or(0);
    let eval_tokens = usage
        .and_then(|u| u.get("completion_tokens"))
        .and_then(|t| t.as_i64())
        .unwrap_or(0);

    Json::obj(vec![
        ("model".into(), Json::str(model)),
        ("created_at".into(), Json::str(rfc3339(created, 0))),
        (
            "message".into(),
            Json::obj(vec![
                ("role".into(), Json::str(role)),
                ("content".into(), Json::str(content)),
            ]),
        ),
        ("done".into(), Json::bool(true)),
        ("done_reason".into(), Json::str(finish)),
        ("prompt_eval_count".into(), Json::num(prompt_tokens as f64)),
        ("eval_count".into(), Json::num(eval_tokens as f64)),
        ("total_duration".into(), Json::num(0.0)),
        ("load_duration".into(), Json::num(0.0)),
        ("prompt_eval_duration".into(), Json::num(0.0)),
        ("eval_duration".into(), Json::num(0.0)),
    ])
}

/// Convert a non-streaming OpenAI completion into an Ollama generate response.
fn openai_completion_to_ollama(model: &str, upstream: &Json) -> Json {
    let created = upstream
        .get("created")
        .and_then(|c| c.as_i64())
        .unwrap_or_else(now_unix);
    let choice = upstream
        .get("choices")
        .and_then(|c| c.as_arr())
        .and_then(|a| a.first());
    let text = choice
        .and_then(|c| c.get("text"))
        .and_then(|t| t.as_str())
        .unwrap_or("");
    let finish = choice
        .and_then(|c| c.get("finish_reason"))
        .and_then(|f| f.as_str())
        .unwrap_or("stop");
    let usage = upstream.get("usage");
    let prompt_tokens = usage
        .and_then(|u| u.get("prompt_tokens"))
        .and_then(|t| t.as_i64())
        .unwrap_or(0);
    let eval_tokens = usage
        .and_then(|u| u.get("completion_tokens"))
        .and_then(|t| t.as_i64())
        .unwrap_or(0);

    Json::obj(vec![
        ("model".into(), Json::str(model)),
        ("created_at".into(), Json::str(rfc3339(created, 0))),
        ("response".into(), Json::str(text)),
        ("done".into(), Json::bool(true)),
        ("done_reason".into(), Json::str(finish)),
        ("prompt_eval_count".into(), Json::num(prompt_tokens as f64)),
        ("eval_count".into(), Json::num(eval_tokens as f64)),
        ("total_duration".into(), Json::num(0.0)),
        ("load_duration".into(), Json::num(0.0)),
        ("prompt_eval_duration".into(), Json::num(0.0)),
        ("eval_duration".into(), Json::num(0.0)),
    ])
}

/// Read all lines from a reader (capped to avoid unbounded memory).
fn lines<R: Read>(mut reader: R) -> Vec<String> {
    let mut out = Vec::new();
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match reader.read(&mut byte) {
            Ok(0) => break,
            Ok(_) => {
                buf.push(byte[0]);
                if byte[0] == b'\n' {
                    out.push(String::from_utf8_lossy(&buf).into_owned());
                    buf.clear();
                    if out.len() > 1_000_000 {
                        break;
                    }
                } else if buf.len() > MAX_LINE {
                    out.push(String::from_utf8_lossy(&buf).into_owned());
                    buf.clear();
                }
            }
            Err(_) => break,
        }
    }
    if !buf.is_empty() {
        out.push(String::from_utf8_lossy(&buf).into_owned());
    }
    out
}

/// Convert an upstream SSE stream (OpenAI chat completions) into Ollama NDJSON
/// written to `client` (chunked).
fn stream_chat_to_client(body_reader: BodyReader, client: &mut TcpStream, model: &str) {
    let mut finish = "stop".to_string();
    let mut prompt_tokens = 0i64;
    let mut eval_tokens = 0i64;
    for line in lines(body_reader) {
        let line = line.trim();
        if !line.starts_with("data:") {
            continue;
        }
        let data = line[5..].trim();
        if data == "[DONE]" {
            break;
        }
        let chunk = match Json::parse(data) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let choice = chunk
            .get("choices")
            .and_then(|c| c.as_arr())
            .and_then(|a| a.first());
        let delta = choice.and_then(|c| c.get("delta"));
        let content = delta
            .and_then(|d| d.get("content"))
            .and_then(|c| c.as_str())
            .unwrap_or("");
        if let Some(fr) = choice
            .and_then(|c| c.get("finish_reason"))
            .and_then(|f| f.as_str())
        {
            if !fr.is_empty() {
                finish = fr.to_string();
            }
        }
        if let Some(u) = chunk.get("usage") {
            if let Some(t) = u.get("prompt_tokens").and_then(|t| t.as_i64()) {
                prompt_tokens = t;
            }
            if let Some(t) = u.get("completion_tokens").and_then(|t| t.as_i64()) {
                eval_tokens = t;
            }
        }
        let msg = Json::obj(vec![
            ("model".into(), Json::str(model)),
            ("created_at".into(), Json::str(rfc3339(now_unix(), 0))),
            (
                "message".into(),
                Json::obj(vec![
                    ("role".into(), Json::str("assistant")),
                    ("content".into(), Json::str(content)),
                ]),
            ),
            ("done".into(), Json::bool(false)),
        ]);
        let mut line_out = msg.to_string();
        line_out.push('\n');
        write_chunk(client, line_out.as_bytes());
    }
    let final_msg = Json::obj(vec![
        ("model".into(), Json::str(model)),
        ("created_at".into(), Json::str(rfc3339(now_unix(), 0))),
        (
            "message".into(),
            Json::obj(vec![
                ("role".into(), Json::str("assistant")),
                ("content".into(), Json::str("")),
            ]),
        ),
        ("done".into(), Json::bool(true)),
        ("done_reason".into(), Json::str(finish)),
        ("prompt_eval_count".into(), Json::num(prompt_tokens as f64)),
        ("eval_count".into(), Json::num(eval_tokens as f64)),
    ]);
    let mut line_out = final_msg.to_string();
    line_out.push('\n');
    write_chunk(client, line_out.as_bytes());
}

/// Convert an upstream SSE stream (OpenAI completions) into Ollama NDJSON.
fn stream_completion_to_client(body_reader: BodyReader, client: &mut TcpStream, model: &str) {
    let mut finish = "stop".to_string();
    let mut prompt_tokens = 0i64;
    let mut eval_tokens = 0i64;
    for line in lines(body_reader) {
        let line = line.trim();
        if !line.starts_with("data:") {
            continue;
        }
        let data = line[5..].trim();
        if data == "[DONE]" {
            break;
        }
        let chunk = match Json::parse(data) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let choice = chunk
            .get("choices")
            .and_then(|c| c.as_arr())
            .and_then(|a| a.first());
        let text = choice
            .and_then(|c| c.get("text"))
            .and_then(|t| t.as_str())
            .unwrap_or("");
        if let Some(fr) = choice
            .and_then(|c| c.get("finish_reason"))
            .and_then(|f| f.as_str())
        {
            if !fr.is_empty() {
                finish = fr.to_string();
            }
        }
        if let Some(u) = chunk.get("usage") {
            if let Some(t) = u.get("prompt_tokens").and_then(|t| t.as_i64()) {
                prompt_tokens = t;
            }
            if let Some(t) = u.get("completion_tokens").and_then(|t| t.as_i64()) {
                eval_tokens = t;
            }
        }
        let msg = Json::obj(vec![
            ("model".into(), Json::str(model)),
            ("created_at".into(), Json::str(rfc3339(now_unix(), 0))),
            ("response".into(), Json::str(text)),
            ("done".into(), Json::bool(false)),
        ]);
        let mut line_out = msg.to_string();
        line_out.push('\n');
        write_chunk(client, line_out.as_bytes());
    }
    let final_msg = Json::obj(vec![
        ("model".into(), Json::str(model)),
        ("created_at".into(), Json::str(rfc3339(now_unix(), 0))),
        ("response".into(), Json::str("")),
        ("done".into(), Json::bool(true)),
        ("done_reason".into(), Json::str(finish)),
        ("prompt_eval_count".into(), Json::num(prompt_tokens as f64)),
        ("eval_count".into(), Json::num(eval_tokens as f64)),
    ]);
    let mut line_out = final_msg.to_string();
    line_out.push('\n');
    write_chunk(client, line_out.as_bytes());
}

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

fn handle_request(cfg: &Arc<Config>, stream: &mut TcpStream, req: Request) {
    let started = Instant::now();
    let method = req.method.clone();
    let path = req.path.clone();

    let result: Result<(), String> = (|| {
        match (method.as_str(), path.as_str()) {
            ("GET", "/api/version") => {
                write_json(
                    stream,
                    200,
                    &Json::obj(vec![("version".into(), Json::str("0.1.0"))]),
                );
                Ok(())
            }
            ("GET", "/api/tags") => handle_tags(cfg, stream),
            ("GET", "/api/ps") => {
                write_json(
                    stream,
                    200,
                    &Json::obj(vec![("models".into(), Json::Arr(vec![]))]),
                );
                Ok(())
            }
            ("POST", "/api/chat") => {
                match parse_body(&req.body) {
                    Ok(body) => handle_chat(cfg, stream, body),
                    Err(e) => {
                        write_json(stream, 400, &Json::obj(vec![("error".into(), Json::str(e))]));
                        Ok(())
                    }
                }
            }
            ("POST", "/api/generate") => {
                match parse_body(&req.body) {
                    Ok(body) => handle_generate(cfg, stream, body),
                    Err(e) => {
                        write_json(stream, 400, &Json::obj(vec![("error".into(), Json::str(e))]));
                        Ok(())
                    }
                }
            }
            ("GET", "/") => {
                write_simple(
                    stream,
                    "200 OK",
                    "text/plain; charset=utf-8",
                    b"ollama-bridge: Ollama-compatible API in front of llama-swap\n",
                );
                Ok(())
            }
            _ => {
                write_json(stream, 404, &Json::obj(vec![("error".into(), Json::str("not found"))]));
                Ok(())
            }
        }
    })();

    let ok = result.is_ok();
    if let Err(msg) = result {
        write_json(
            stream,
            502,
            &Json::obj(vec![("error".into(), Json::str(msg))]),
        );
    }

    let dur = started.elapsed();
    eprintln!(
        "[ollama-bridge] {} {} -> {} ({} ms)",
        method,
        path,
        if ok { "ok" } else { "error" },
        dur.as_millis()
    );
}

fn handle_tags(cfg: &Arc<Config>, stream: &mut TcpStream) -> Result<(), String> {
    let (status, body) = upstream_json(cfg, "GET", "/models", None)?;
    if status != 200 {
        return Err(format!("upstream /models returned status {status}"));
    }
    let mut models: Vec<Json> = Vec::new();
    if let Some(data) = body.get("data").and_then(|d| d.as_arr()) {
        for item in data {
            if let Some(id) = item.get("id").and_then(|i| i.as_str()) {
                models.push(Json::obj(vec![
                    ("name".into(), Json::str(id)),
                    ("model".into(), Json::str(id)),
                    ("modified_at".into(), Json::str(rfc3339(now_unix(), 0))),
                    ("size".into(), Json::num(0.0)),
                    ("digest".into(), Json::str("")),
                    (
                        "details".into(),
                        Json::obj(vec![
                            ("parent_model".into(), Json::str("")),
                            ("format".into(), Json::str("gguf")),
                            ("family".into(), Json::str("llama")),
                            ("families".into(), Json::Arr(vec![Json::str("llama")])),
                            ("parameter_size".into(), Json::str("")),
                            ("quantization_level".into(), Json::str("")),
                        ]),
                    ),
                ]));
            }
        }
    }
    write_json(stream, 200, &Json::obj(vec![("models".into(), Json::Arr(models))]));
    Ok(())
}

fn handle_chat(cfg: &Arc<Config>, stream: &mut TcpStream, body: Json) -> Result<(), String> {
    let model = body
        .get("model")
        .and_then(|m| m.as_str())
        .unwrap_or(&cfg.model)
        .to_string();
    let stream_requested = body.get("stream").and_then(|s| s.as_bool()).unwrap_or(false);
    let openai = build_openai_chat(cfg, &body)?;

    if stream_requested {
        let (status, reader) = upstream_stream(cfg, "POST", "/chat/completions", &openai)?;
        if status != 200 {
            return Err(format!("upstream /chat/completions returned status {status}"));
        }
        let _ = stream.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson; charset=utf-8\r\nTransfer-Encoding: chunked\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        );
        stream_chat_to_client(reader, stream, &model);
        write_chunk_end(stream);
    } else {
        let (status, resp) = upstream_json(cfg, "POST", "/chat/completions", Some(&openai))?;
        if status != 200 {
            let msg = resp
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(|m| m.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("upstream returned status {status}"));
            write_json(stream, 502, &Json::obj(vec![("error".into(), Json::str(msg))]));
            return Ok(());
        }
        let ollama = openai_chat_to_ollama(&model, &resp);
        write_json(stream, 200, &ollama);
    }
    Ok(())
}

fn handle_generate(cfg: &Arc<Config>, stream: &mut TcpStream, body: Json) -> Result<(), String> {
    let model = body
        .get("model")
        .and_then(|m| m.as_str())
        .unwrap_or(&cfg.model)
        .to_string();
    let stream_requested = body.get("stream").and_then(|s| s.as_bool()).unwrap_or(false);
    let openai = build_openai_completions(cfg, &body)?;

    if stream_requested {
        let (status, reader) = upstream_stream(cfg, "POST", "/completions", &openai)?;
        if status != 200 {
            return Err(format!("upstream /completions returned status {status}"));
        }
        let _ = stream.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson; charset=utf-8\r\nTransfer-Encoding: chunked\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        );
        stream_completion_to_client(reader, stream, &model);
        write_chunk_end(stream);
    } else {
        let (status, resp) = upstream_json(cfg, "POST", "/completions", Some(&openai))?;
        if status != 200 {
            let msg = resp
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(|m| m.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("upstream returned status {status}"));
            write_json(stream, 502, &Json::obj(vec![("error".into(), Json::str(msg))]));
            return Ok(());
        }
        let ollama = openai_completion_to_ollama(&model, &resp);
        write_json(stream, 200, &ollama);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

fn handle_client(stream: TcpStream, cfg: Arc<Config>) {
    let mut stream = stream;
    let reader = BufReader::new(stream.try_clone().expect("clone stream"));
    let mut reader = reader;
    let req = match read_request(&mut reader) {
        Ok(r) => r,
        Err(msg) => {
            if msg == "connection closed" {
                return;
            }
            if msg == "body too large" {
                write_json(
                    &mut stream,
                    413,
                    &Json::obj(vec![("error".into(), Json::str("body too large"))]),
                );
                return;
            }
            write_json(&mut stream, 400, &Json::obj(vec![("error".into(), Json::str(msg))]));
            return;
        }
    };
    handle_request(&cfg, &mut stream, req);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut cfg = Config {
        listen: "0.0.0.0:11434".to_string(),
        upstream_host: "127.0.0.1:8081".to_string(),
        upstream_prefix: "/upstream/vulkan/v1".to_string(),
        model: "vulkan".to_string(),
        max_tokens: 512,
    };
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--listen" => {
                i += 1;
                if i < args.len() {
                    cfg.listen = args[i].clone();
                }
            }
            "--upstream" => {
                i += 1;
                if i < args.len() {
                    let url = args[i].clone();
                    let rest = url
                        .strip_prefix("http://")
                        .unwrap_or_else(|| {
                            eprintln!("error: --upstream must be an http:// URL");
                            std::process::exit(1);
                        });
                    match rest.split_once('/') {
                        Some((host, prefix)) => {
                            cfg.upstream_host = host.to_string();
                            cfg.upstream_prefix = format!("/{}", prefix.trim_end_matches('/'));
                        }
                        None => {
                            cfg.upstream_host = rest.to_string();
                            cfg.upstream_prefix = String::new();
                        }
                    }
                }
            }
            "--model" => {
                i += 1;
                if i < args.len() {
                    cfg.model = args[i].clone();
                }
            }
            "--max-tokens" => {
                i += 1;
                if i < args.len() {
                    cfg.max_tokens = args[i].parse().unwrap_or(512);
                }
            }
            "--help" | "-h" => {
                println!(
                    "usage: ollama-bridge [--listen HOST:PORT] [--upstream BASE_URL] [--model NAME] [--max-tokens N]\n\
                     default upstream: http://127.0.0.1:8081/upstream/vulkan/v1"
                );
                return;
            }
            _ => {}
        }
        i += 1;
    }

    let cfg = Arc::new(cfg);
    let listener = match TcpListener::bind(&cfg.listen) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error: failed to bind {}: {e}", cfg.listen);
            std::process::exit(1);
        }
    };
    println!(
        "ollama-bridge listening on http://{} (upstream: http://{}:{})",
        cfg.listen, cfg.upstream_host, cfg.upstream_prefix
    );

    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                let c = Arc::clone(&cfg);
                thread::spawn(move || handle_client(s, c));
            }
            Err(_) => continue,
        }
    }
}
