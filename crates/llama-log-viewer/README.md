# Llama Log Viewer

A small zero-dependency web viewer for [`llama-server --log-prompts-dir`](https://github.com/ggml-org/llama.cpp)
log files. Each log file is one API call containing the **complete context**
(system prompt plus every turn). Because every call re-sends the full context,
there is massive duplication between files — this tool collapses it into a tree.

## How it works

1. Every `.txt` file in the log directory is parsed into a sequence of
   messages (role + content). Both common formats are handled:
   - Qwen chat template: `<|im_start|>system … <|im_end|>`
   - opencode / poolside style: `<system>…</system> <user>…</user> <assistant>…</assistant>`
2. A **trie** is built over the message sequences. Messages are only merged
   when they are reached through the same parent (i.e. the same context
   prefix), so:
   - shared system prompts / repeated context appear **once**,
   - conversations diverge into **branches** where their contexts differ,
   - a **leaf** is a node where one or more files end — a complete API call.
3. A tiny HTTP server (Rust stdlib only, frontend embedded via `include_str!`)
   serves a single-page UI plus a JSON API. The index is rebuilt automatically
   whenever new log files appear (fingerprint check on each request).

## Running

```sh
# Dev build (needs Rust + a C linker)
cargo build --release
./target/release/llama-log-viewer --logs /path/to/llama-logs --port 8083

# Or via Nix
nix build --impure --expr 'with import <nixpkgs> {}; rustPlatform.buildRustPackage { pname = "llama-log-viewer"; version = "0.1.0"; src = ./.; cargoLock.lockFile = ./Cargo.lock; doCheck = false; }'
```

Then open <http://127.0.0.1:8083>.

## API

| Endpoint | Description |
| --- | --- |
| `GET /api/stats` | file/node/root counts |
| `GET /api/roots` | distinct first messages (usually system prompts) |
| `GET /api/node?id=N` | node + its children (branches) |
| `GET /api/path?id=N` | full path from root to node (the conversation) |
| `GET /api/content?id=N` | full message content |
| `GET /api/files?node=N` | log files ending at a node (complete calls) |
| `GET /api/search?q=…` | full-text search over unique messages |
| `GET /api/raw?file=NAME` | raw contents of one log file |

## NixOS service

`hosts/zen3-nixos/ai.nix` builds the package via `rustPlatform.buildRustPackage`
and exposes it as a systemd service `llama-log-viewer` (port 8083) behind the
existing nginx virtual host at `/logs`.
