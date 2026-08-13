//! Llama Log Viewer
//!
//! Serves a web UI for browsing llama.cpp `--log-prompts-dir` log files.
//! Each log file is one API call containing the complete context (system
//! prompt plus every turn). This tool parses every file into a sequence of
//! messages, then builds a trie so shared prefixes (common system prompts /
//! repeated context) are deduplicated and divergences become branches. A node
//! is a "leaf" when one or more files end at it — i.e. a complete conversation.
//!
//! Zero dependencies: Rust stdlib only. The frontend is embedded at compile
//! time via `include_str!`, so the resulting binary is fully self-contained.

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Static assets (embedded at compile time)
// ---------------------------------------------------------------------------

const INDEX_HTML: &str = include_str!("../index.html");
const APP_JS: &str = include_str!("../app.js");
const STYLE_CSS: &str = include_str!("../style.css");

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Role {
    System,
    User,
    Assistant,
    Tool,
}

impl Role {
    fn as_str(self) -> &'static str {
        match self {
            Role::System => "system",
            Role::User => "user",
            Role::Assistant => "assistant",
            Role::Tool => "tool",
        }
    }

    fn from_str(s: &str) -> Option<Role> {
        match s {
            "system" => Some(Role::System),
            "user" => Some(Role::User),
            "assistant" => Some(Role::Assistant),
            "tool" | "tool_response" => Some(Role::Tool),
            _ => None,
        }
    }
}

/// Qwen chat template: `<|im_start|>role\n...<|im_end|>`
fn parse_qwen(text: &str) -> Vec<(Role, String)> {
    const TOKEN: &str = "<|im_start|>";
    let mut messages = Vec::new();
    let mut pending: Option<(usize, Role)> = None; // (content_start, role)
    let mut search_pos = 0usize;

    loop {
        let rest = &text[search_pos..];
        let Some(rel) = rest.find(TOKEN) else { break };
        let tok_start = search_pos + rel;
        let after = tok_start + TOKEN.len();
        let line_end = text[after..]
            .find('\n')
            .map(|i| after + i)
            .unwrap_or(text.len());
        let role_str = text[after..line_end].trim();

        if let Some(role) = Role::from_str(role_str) {
            // Finalise the previous message: content up to this token (or its <|im_end|>).
            if let Some((cstart, crole)) = pending.take() {
                let end = text[cstart..tok_start]
                    .find("<|im_end|>")
                    .map(|i| cstart + i)
                    .unwrap_or(tok_start);
                messages.push((crole, text[cstart..end].to_string()));
            }
            let content_start = (line_end + 1).min(text.len());
            pending = Some((content_start, role));
            search_pos = content_start;
        } else {
            search_pos = after;
        }
    }

    if let Some((cstart, crole)) = pending {
        let end = text[cstart..]
            .find("<|im_end|>")
            .map(|i| cstart + i)
            .unwrap_or(text.len());
        messages.push((crole, text[cstart..end].to_string()));
    }
    messages
}

/// `<system>...</system>` / `<user>` / `<assistant>` / `<tool_response>` files
/// (opencode / poolside style).
fn parse_html(text: &str) -> Vec<(Role, String)> {
    const OPENS: [(&str, &str, Role); 4] = [
        ("<system>", "</system>", Role::System),
        ("<user>", "</user>", Role::User),
        ("<assistant>", "</assistant>", Role::Assistant),
        ("<tool_response>", "</tool_response>", Role::Tool),
    ];

    let mut messages = Vec::new();
    let mut pos = 0usize;

    while pos < text.len() {
        let rest = &text[pos..];
        let mut best: Option<(usize, &str, &str, Role)> = None;
        for (open, close, role) in OPENS {
            if let Some(rel) = rest.find(open) {
                if best.map_or(true, |(bp, ..)| rel < bp) {
                    best = Some((rel, open, close, role));
                }
            }
        }
        let Some((rel, open, close, role)) = best else { break };

        let content_start = pos + rel + open.len();

        // Bound the search for the closing tag by the next opening tag.
        let mut next_open = text.len();
        for (o2, _, _) in OPENS {
            if let Some(r2) = text[content_start..].find(o2) {
                next_open = next_open.min(content_start + r2);
            }
        }

        let content_end = text[content_start..next_open]
            .find(close)
            .map(|i| content_start + i)
            .unwrap_or(next_open);

        messages.push((role, text[content_start..content_end].to_string()));
        pos = content_end;
    }
    messages
}

fn parse_file(path: &Path) -> Vec<(Role, String)> {
    let text = fs::read_to_string(path).unwrap_or_default();
    if text.contains("<|im_start|>") {
        parse_qwen(&text)
    } else {
        parse_html(&text)
    }
}

fn make_preview(content: &str, limit: usize) -> String {
    let collapsed: String = content.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= limit {
        collapsed
    } else {
        let mut s: String = collapsed.chars().take(limit).collect();
        s.push('…');
        s
    }
}

// ---------------------------------------------------------------------------
// Index: trie of message sequences
// ---------------------------------------------------------------------------

struct Node {
    role: Role,
    content_id: usize, // index into Index::contents
    count: usize,      // number of files passing through this node
    ends: Vec<String>, // filenames whose last message is this node
    children: Vec<usize>,
    child_keys: HashMap<(Role, u64), Vec<usize>>, // (role, content hash) -> child node ids
}

struct Index {
    logdir: PathBuf,
    fingerprint: Option<Vec<(String, u128, u64)>>, // (name, mtime_ns, size)
    nodes: Vec<Node>,
    contents: Vec<String>,              // unique message contents
    content_by_hash: HashMap<u64, Vec<usize>>, // content hash -> content ids
    root_keys: HashMap<(Role, u64), Vec<usize>>, // (role, content hash) -> root node ids
    roots: Vec<usize>,                  // node ids of first messages
    file_info: HashMap<String, (u64, f64)>, // name -> (size, mtime_secs)
}

fn fnv1a(s: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

impl Index {
    fn new(logdir: PathBuf) -> Index {
        Index {
            logdir,
            fingerprint: None,
            nodes: Vec::new(),
            contents: Vec::new(),
            content_by_hash: HashMap::new(),
            root_keys: HashMap::new(),
            roots: Vec::new(),
            file_info: HashMap::new(),
        }
    }

    fn fingerprint_of(&self) -> Option<Vec<(String, u128, u64)>> {
        let mut names: Vec<String> = fs::read_dir(&self.logdir)
            .ok()?
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".txt"))
            .collect();
        names.sort();
        let mut sig = Vec::with_capacity(names.len());
        for n in &names {
            let md = fs::metadata(self.logdir.join(n)).ok()?;
            let mtime = md
                .modified()
                .ok()?
                .duration_since(UNIX_EPOCH)
                .ok()?
                .as_nanos();
            sig.push((n.clone(), mtime, md.len()));
        }
        Some(sig)
    }

    fn rebuild_if_changed(&mut self) -> bool {
        let fp = self.fingerprint_of();
        if fp != self.fingerprint {
            self.rebuild();
            self.fingerprint = fp;
            true
        } else {
            false
        }
    }

    fn child_id(
        nodes: &mut Vec<Node>,
        contents: &mut Vec<String>,
        content_by_hash: &mut HashMap<u64, Vec<usize>>,
        keys: &mut HashMap<(Role, u64), Vec<usize>>,
        role: Role,
        content: &str,
    ) -> usize {
        let h = fnv1a(content);
        let key = (role, h);
        if let Some(ids) = keys.get(&key) {
            for &nid in ids {
                if contents[nodes[nid].content_id] == content {
                    return nid;
                }
            }
        }
        // Content dedup (shared across roles / positions).
        let cid = if let Some(ids) = content_by_hash.get(&h) {
            let mut found = None;
            for &id in ids {
                if contents[id] == content {
                    found = Some(id);
                    break;
                }
            }
            match found {
                Some(id) => id,
                None => {
                    let id = contents.len();
                    contents.push(content.to_string());
                    content_by_hash.entry(h).or_default().push(id);
                    id
                }
            }
        } else {
            let id = contents.len();
            contents.push(content.to_string());
            content_by_hash.insert(h, vec![id]);
            id
        };
        let nid = nodes.len();
        nodes.push(Node {
            role,
            content_id: cid,
            count: 0,
            ends: Vec::new(),
            children: Vec::new(),
            child_keys: HashMap::new(),
        });
        keys.entry(key).or_default().push(nid);
        nid
    }

    fn rebuild(&mut self) {
        self.nodes.clear();
        self.contents.clear();
        self.content_by_hash.clear();
        self.root_keys.clear();
        self.roots.clear();
        self.file_info.clear();

        let mut names: Vec<String> = fs::read_dir(&self.logdir)
            .map(|rd| {
                rd.filter_map(|e| e.ok())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| n.ends_with(".txt"))
                    .collect()
            })
            .unwrap_or_default();
        names.sort();

        for name in names {
            let path = self.logdir.join(&name);
            let md = match fs::metadata(&path) {
                Ok(m) => m,
                Err(_) => continue,
            };
            let mtime = md
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            self.file_info.insert(name.clone(), (md.len(), mtime));

            let messages = parse_file(&path);
            let mut parent: Option<usize> = None;
            for (role, content) in messages {
                // Reuse a node only when it is reached through the same parent
                // (i.e. the same message prefix), keeping the trie acyclic.
                let nid = match parent {
                    None => Index::child_id(
                        &mut self.nodes,
                        &mut self.contents,
                        &mut self.content_by_hash,
                        &mut self.root_keys,
                        role,
                        &content,
                    ),
                    Some(p) => {
                        let mut keys = std::mem::take(&mut self.nodes[p].child_keys);
                        let nid = Index::child_id(
                            &mut self.nodes,
                            &mut self.contents,
                            &mut self.content_by_hash,
                            &mut keys,
                            role,
                            &content,
                        );
                        self.nodes[p].child_keys = keys;
                        nid
                    }
                };
                self.nodes[nid].count += 1;
                match parent {
                    None => self.roots.push(nid),
                    Some(p) => {
                        if !self.nodes[p].children.contains(&nid) {
                            self.nodes[p].children.push(nid);
                        }
                    }
                }
                parent = Some(nid);
            }
            if let Some(p) = parent {
                self.nodes[p].ends.push(name.clone());
            }
        }

        // Dedupe roots, preserving first-seen order.
        let mut seen = std::collections::HashSet::new();
        self.roots.retain(|&nid| seen.insert(nid));
    }

    // -- queries ------------------------------------------------------------

    fn node_summary(&self, nid: usize) -> String {
        let n = &self.nodes[nid];
        let content = &self.contents[n.content_id];
        format!(
            "{{\"id\":{},\"role\":\"{}\",\"preview\":\"{}\",\"length\":{},\"count\":{},\"ends\":{},\"children\":{},\"is_leaf\":{}}}",
            nid,
            n.role.as_str(),
            json_escape(&make_preview(content, 200)),
            content.len(),
            n.count,
            n.ends.len(),
            n.children.len(),
            if n.children.is_empty() { "true" } else { "false" },
        )
    }

    fn stats(&self) -> String {
        format!(
            "{{\"files\":{},\"nodes\":{},\"unique_messages\":{},\"roots\":{},\"updated\":{}}}",
            self.file_info.len(),
            self.nodes.len(),
            self.contents.len(),
            self.roots.len(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0),
        )
    }

    fn path_to(&self, nid: usize) -> Vec<usize> {
        // Build parent pointers by walking down from the roots, guarding
        // against any residual cycles.
        let mut parent: HashMap<usize, usize> = HashMap::new();
        let mut visited: std::collections::HashSet<usize> = std::collections::HashSet::new();
        let mut stack: Vec<usize> = self.roots.clone();
        while let Some(cur) = stack.pop() {
            if !visited.insert(cur) {
                continue;
            }
            for &c in &self.nodes[cur].children {
                parent.insert(c, cur);
                stack.push(c);
            }
        }
        let mut path = Vec::new();
        let mut cur = nid;
        while let Some(&p) = parent.get(&cur) {
            path.push(cur);
            cur = p;
        }
        path.push(cur);
        path.reverse();
        if path.last() != Some(&nid) {
            return Vec::new();
        }
        path
    }

    fn deepest_path(&self, nid: usize) -> Vec<usize> {
        // Longest thread below nid: the deepest descendant. At equal depth
        // prefer nodes where API calls end, then higher counts. Guarded
        // against residual cycles.
        let mut best: Vec<usize> = vec![nid];
        let mut best_score: (usize, bool, usize) = (0, false, 0); // (depth, ends>0, count)
        let mut visited: std::collections::HashSet<usize> = std::collections::HashSet::new();
        let mut stack: Vec<(usize, Vec<usize>)> = vec![(nid, vec![nid])];
        while let Some((cur, path)) = stack.pop() {
            if !visited.insert(cur) {
                continue;
            }
            let n = &self.nodes[cur];
            let score = (path.len(), !n.ends.is_empty(), n.count);
            if score > best_score {
                best_score = score;
                best = path.clone();
            }
            for &c in &n.children {
                let mut p = path.clone();
                p.push(c);
                stack.push((c, p));
            }
        }
        best
    }

    fn search(&self, query: &str, limit: usize) -> String {
        let q = query.to_lowercase();
        let mut results = Vec::new();
        for (nid, n) in self.nodes.iter().enumerate() {
            let content = &self.contents[n.content_id];
            if content.to_lowercase().contains(&q) {
                results.push(self.node_summary(nid));
                if results.len() >= limit {
                    break;
                }
            }
        }
        format!("{{\"results\":[{}]}}", results.join(","))
    }
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 16);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

fn send_response(stream: &mut TcpStream, status: &str, ctype: &str, body: &[u8], head_only: bool) {
    let header = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        status, ctype, body.len()
    );
    let _ = stream.write_all(header.as_bytes());
    if !head_only {
        let _ = stream.write_all(body);
    }
    let _ = stream.flush();
}

fn percent_decode(s: &str) -> String {
    fn hex(c: u8) -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        if bytes[i] == b'+' {
            out.push(b' ');
        } else {
            out.push(bytes[i]);
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn parse_query(query: &str) -> HashMap<String, String> {
    let mut params = HashMap::new();
    for pair in query.split('&') {
        if pair.is_empty() {
            continue;
        }
        if let Some((k, v)) = pair.split_once('=') {
            params.insert(percent_decode(k), percent_decode(v));
        } else {
            params.insert(percent_decode(pair), String::new());
        }
    }
    params
}

fn route(path: &str, params: &HashMap<String, String>, index: &Index) -> (String, String, Vec<u8>) {
    let json = |obj: String| -> (String, String, Vec<u8>) {
        (
            "200 OK".to_string(),
            "application/json; charset=utf-8".to_string(),
            obj.into_bytes(),
        )
    };

    match path {
        "/" | "/index.html" => (
            "200 OK".into(),
            "text/html; charset=utf-8".into(),
            INDEX_HTML.as_bytes().to_vec(),
        ),
        "/app.js" => (
            "200 OK".into(),
            "application/javascript; charset=utf-8".into(),
            APP_JS.as_bytes().to_vec(),
        ),
        "/style.css" => (
            "200 OK".into(),
            "text/css; charset=utf-8".into(),
            STYLE_CSS.as_bytes().to_vec(),
        ),
        "/api/stats" => json(index.stats()),
        "/api/roots" => {
            let mut roots: Vec<(usize, String)> = index
                .roots
                .iter()
                .map(|&nid| (nid, index.node_summary(nid)))
                .collect();
            roots.sort_by(|a, b| {
                let ca = index.nodes[a.0].count;
                let cb = index.nodes[b.0].count;
                cb.cmp(&ca).then(a.0.cmp(&b.0))
            });
            let body = format!(
                "{{\"roots\":[{}]}}",
                roots.iter().map(|(_, s)| s.as_str()).collect::<Vec<_>>().join(",")
            );
            json(body)
        }
        "/api/node" => {
            let id: usize = match params.get("id").and_then(|v| v.parse().ok()) {
                Some(v) => v,
                None => return json("{\"error\":\"bad id\"}".into()),
            };
            if id >= index.nodes.len() {
                return json("{\"error\":\"bad id\"}".into());
            }
            let mut children: Vec<(usize, String)> = index.nodes[id]
                .children
                .iter()
                .map(|&cid| (cid, index.node_summary(cid)))
                .collect();
            children.sort_by(|a, b| {
                let ca = index.nodes[a.0].count;
                let cb = index.nodes[b.0].count;
                cb.cmp(&ca).then(a.0.cmp(&b.0))
            });
            let body = format!(
                "{{\"node\":{},\"children\":[{}]}}",
                index.node_summary(id),
                children.iter().map(|(_, s)| s.as_str()).collect::<Vec<_>>().join(",")
            );
            json(body)
        }
        "/api/path" => {
            let id: usize = match params.get("id").and_then(|v| v.parse().ok()) {
                Some(v) => v,
                None => return json("{\"error\":\"bad id\"}".into()),
            };
            if id >= index.nodes.len() {
                return json("{\"error\":\"bad id\"}".into());
            }
            let path_ids = index.path_to(id);
            if path_ids.is_empty() {
                return json("{\"error\":\"not found\"}".into());
            }
            let steps: Vec<String> = path_ids.iter().map(|&pid| index.node_summary(pid)).collect();
            let ends: Vec<String> = index.nodes[id]
                .ends
                .iter()
                .map(|e| format!("\"{}\"", json_escape(e)))
                .collect();
            let body = format!(
                "{{\"steps\":[{}],\"ends\":[{}]}}",
                steps.join(","),
                ends.join(",")
            );
            json(body)
        }
        "/api/deepest" => {
            let id: usize = match params.get("id").and_then(|v| v.parse().ok()) {
                Some(v) => v,
                None => return json("{\"error\":\"bad id\"}".into()),
            };
            if id >= index.nodes.len() {
                return json("{\"error\":\"bad id\"}".into());
            }
            let path_ids = index.deepest_path(id);
            let steps: Vec<String> = path_ids.iter().map(|&pid| index.node_summary(pid)).collect();
            let body = format!("{{\"path\":[{}]}}", steps.join(","));
            json(body)
        }
        "/api/content" => {
            let id: usize = match params.get("id").and_then(|v| v.parse().ok()) {
                Some(v) => v,
                None => return json("{\"error\":\"bad id\"}".into()),
            };
            if id >= index.nodes.len() {
                return json("{\"error\":\"bad id\"}".into());
            }
            let n = &index.nodes[id];
            let content = &index.contents[n.content_id];
            let body = format!(
                "{{\"id\":{},\"role\":\"{}\",\"content\":\"{}\"}}",
                id,
                n.role.as_str(),
                json_escape(content)
            );
            json(body)
        }
        "/api/files" => {
            let mut names: Vec<String> = Vec::new();
            if let Some(v) = params.get("node") {
                if let Ok(nid) = v.parse::<usize>() {
                    if nid < index.nodes.len() {
                        names = index.nodes[nid].ends.clone();
                    }
                }
            }
            names.sort();
            let mut files = Vec::new();
            for n in &names {
                if let Some((size, mtime)) = index.file_info.get(n) {
                    files.push(format!(
                        "{{\"name\":\"{}\",\"size\":{},\"mtime\":{}}}",
                        json_escape(n),
                        size,
                        mtime
                    ));
                }
            }
            let body = format!("{{\"files\":[{}]}}", files.join(","));
            json(body)
        }
        "/api/search" => {
            let q = params.get("q").cloned().unwrap_or_default();
            if q.trim().is_empty() {
                return json("{\"results\":[]}".into());
            }
            json(index.search(q.trim(), 100))
        }
        "/api/raw" => {
            let name = params.get("file").cloned().unwrap_or_default();
            let ok = !name.is_empty()
                && Path::new(&name)
                    .file_name()
                    .map(|f| f.to_string_lossy().as_ref() == name.as_str())
                    .unwrap_or(false)
                && index.file_info.contains_key(&name);
            if !ok {
                return json("{\"error\":\"bad file\"}".into());
            }
            let path = index.logdir.join(&name);
            let content = fs::read_to_string(&path).unwrap_or_default();
            let body = format!(
                "{{\"name\":\"{}\",\"content\":\"{}\"}}",
                json_escape(&name),
                json_escape(&content)
            );
            json(body)
        }
        _ => json("{\"error\":\"not found\"}".into()),
    }
}

fn handle_connection(mut stream: TcpStream, index: Arc<Mutex<Index>>) {
    let mut buf = [0u8; 65536];
    let n = match stream.read(&mut buf) {
        Ok(n) => n,
        Err(_) => return,
    };
    let req = String::from_utf8_lossy(&buf[..n]);
    let request_line = req.lines().next().unwrap_or("");
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");

    if method != "GET" && method != "HEAD" {
        send_response(
            &mut stream,
            "405 Method Not Allowed",
            "text/plain",
            b"method not allowed",
            method == "HEAD",
        );
        return;
    }

    let (path, query) = match target.find('?') {
        Some(qi) => (&target[..qi], &target[qi + 1..]),
        None => (target, ""),
    };
    let params = parse_query(query);

    {
        let mut idx = index.lock().unwrap();
        idx.rebuild_if_changed();
    }

    let (status, ctype, body) = route(path, &params, &index.lock().unwrap());
    send_response(&mut stream, &status, &ctype, &body, method == "HEAD");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut logdir = String::new();
    let mut host = "127.0.0.1".to_string();
    let mut port: u16 = 8083;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--logs" => {
                i += 1;
                if i < args.len() {
                    logdir = args[i].clone();
                }
            }
            "--host" => {
                i += 1;
                if i < args.len() {
                    host = args[i].clone();
                }
            }
            "--port" => {
                i += 1;
                if i < args.len() {
                    port = args[i].parse().unwrap_or(8083);
                }
            }
            _ => {}
        }
        i += 1;
    }

    if logdir.is_empty() || !Path::new(&logdir).is_dir() {
        eprintln!("error: --logs must point to a directory of llama-cpp prompt log files");
        std::process::exit(1);
    }

    let index = Arc::new(Mutex::new(Index::new(PathBuf::from(&logdir))));
    {
        let mut idx = index.lock().unwrap();
        idx.rebuild();
        println!(
            "llama-log-viewer: {} files, {} nodes, {} unique messages",
            idx.file_info.len(),
            idx.nodes.len(),
            idx.contents.len()
        );
    }

    let listener = match TcpListener::bind((host.as_str(), port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error: failed to bind {host}:{port}: {e}");
            std::process::exit(1);
        }
    };
    println!("llama-log-viewer listening on http://{host}:{port}");
    println!("logs dir: {logdir}");

    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                let idx = Arc::clone(&index);
                thread::spawn(move || handle_connection(s, idx));
            }
            Err(_) => continue,
        }
    }
}
