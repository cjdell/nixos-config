#!/usr/bin/env python3
"""strata-swap — the model-selecting front for Strata on zen3-nixos.

WHY. One R9700 holds one Strata engine: flash-next v31 wants the whole card
(expert cache ~24.5 GiB of 32) and Qwen3.6-35B-A3B wants ~26 GiB of it, so
"serve both models" can only mean "swap them", and a swap is a stop + a
multi-minute load — llama-swap's whole reason for existing, which we buried
in 2026-09-26 because llama.cpp routing no longer described this box. Strata's
serve layer has no such front either, by design: one config JSON -> one engine
-> one model, and the request's `model` field is cosmetic
(server.py model_for(): "Other names are still served, as before").

WHAT THIS IS. A stdlib-only HTTP proxy on 127.0.0.1:8080 — the port every
nginx location (IP vhost "/", strata.ai, llm.ai, /recallium-llm via the
thinking-shim) already proxies to — so no client URL changes. One Strata
SERVE process per selectable model lives behind it on loopback ports
(strata.service -> 8091, strata-<key>.service -> 8092, ...; the table is
declared in ./strata.nix — entries say `selectable = true` — and partners
start only on demand):

  GET  /v1/models      advertises ALL table models: the live engine's own
                       entries, plus the other ids listed {"status":
                       {"value": "unloaded"}} — the same "listed, loads on
                       use" form the serve layer itself uses for an
                       idle-unloaded model.
  POST /v1/chat/completions (and /v1/completions, /v1/messages,
                       /v1/responses)   — the body's `model`, EXACT-matched
                       against the table, picks the engine. A name that is not
                       in the table (absent included) is NOT a switch request:
                       it goes to the live engine untouched, which is how
                       Recallium's ancient "Qwen3-4B-Instruct" row and every
                       other name-blind client keeps working.
  everything else      transparent pass-through to the live engine.

THE SWAP, and its rules (./gpu-mode.nix is the lease owner; this shim only
ever moves WITHIN the llm lease):

  * It NEVER starts an engine onto a silent card: with nothing live the shim
    503s ("gpu-mode llm") — a stray request must not grab the VRAM mid-game,
    the same invariant gpu-mode exists for.
  * Mismatch -> WAIT for the live engine to finish the request it is answering
    (activity.in_flight, up to SWAP_DRAIN_SECS), then stop the live unit, wait
    until amd-smi reports the target's vram_min_mib free, start the target
    unit, wait until its /v1/status says loaded, then forward the buffered
    request. If the turn is still running at the deadline nothing is stopped:
    the request gets a 409 "busy" and the running generation survives. One
    swap at a time (lock); requests for the other model queue behind it,
    requests naming the live model never touch the lock.
  * A liveness/readiness completion — answer budget <= SWAP_PROBE_MAX_TOKENS
    AND prompt text <= SWAP_PROBE_MAX_CHARS — is answered by the LIVE engine
    even when it names another model. "Are you still there?" gets a nod; it
    never pays a 30-90 s model reload (and never stops someone else's turn).
  * A swap whose engine fails to come up RESTARTS the unit it had stopped
    before answering 503 — a broken second model must never strand the LLM.
  * No swap ever kills a running generation any more (2026-11-23: two clients
    naming different models turned every turn into a reload and every
    reload into a killed request). Decisions are logged to the journal.

Env: SWAP_CONFIG = the JSON table (written by ./strata.nix):
  {"models": [{"id","unit","port","vram_min_mib","kind"?}...], "default_port": N}
  kind (default "strata") is the engine's readiness/drain dialect:
    strata — GET /v1/status: loaded:true, activity.in_flight;
    llama  — GET /slots (a llama-server endpoint, answered only once the
             model has loaded, empty list = idle; needs --slots): loaded =
             the endpoint answers, in_flight = slots with state "processing"
             (or the older "processing": true). ./inkling.nix is this kind:
             Inkling-2-Mini's inkling2_loop arch matches no Strata family,
             so the swap table covers llama.cpp engines as well — swap,
             rollback and the lease invariant work identically. While a
             llama engine is live the shim SYNTHESIZES /v1/status itself
             (llama-server has none) so gpu-mode.sh's json_field parsing
             keeps working per kind.
  SWAP_PROBE_MAX_TOKENS (default 4), SWAP_PROBE_MAX_CHARS (default 1024),
  SWAP_DRAIN_SECS (default 180, 0 = never wait).
"""

import http.client
import json
import os
import select
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_PATH = os.environ.get("SWAP_CONFIG", "/etc/strata-swap.json")
LISTEN_PORT = int(os.environ.get("SWAP_LISTEN_PORT", "8080"))

# A health/readiness completion must never cost a model swap: both of these
# must hold (answer budget and total message text) for a request to be treated
# as a probe and answered by the live engine. Anything with a real budget or
# real content takes the normal swap path.
PROBE_MAX_TOKENS = int(os.environ.get("SWAP_PROBE_MAX_TOKENS", "4"))
PROBE_MAX_CHARS = int(os.environ.get("SWAP_PROBE_MAX_CHARS", "1024"))
# Seconds to let the live engine finish an in-flight request before a swap.
# A swap with one running kills it mid-stream; at the deadline we answer 503
# and leave the running turn alone. 0 disables the wait.
DRAIN_SECS = int(os.environ.get("SWAP_DRAIN_SECS", "180"))

# Endpoints whose JSON body carries the OpenAI-style `model` field.
MODEL_BODY_PATHS = {
    "/v1/chat/completions",
    "/v1/completions",
    "/v1/messages",  # the Anthropic dialect serve also speaks
    "/v1/responses",
    "/v1/embeddings",
}

# Never forwarded: connection framing is ours, not the client's (as in
# ./recallium-llm-shim.py, which this mirrors).
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}

with open(CONFIG_PATH) as f:
    CFG = json.load(f)
MODELS = CFG["models"]
BY_ID = {m["id"]: m for m in MODELS}
BOOT = MODELS[0]["id"]  # the primary unit; also the boot model

swap_lock = threading.Lock()


def log(*a):
    print("strata-swap:", *a, flush=True)


def status_of(port, timeout=3.0):
    """The engine's /v1/status JSON, or None if its serve layer is not answering."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/status", timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception:
        return None


def llama_slots(model, timeout=3.0):
    """(loaded, in_flight) from llama-server's /slots, or (None, None).

    llama-server starts serving ONLY after the model is fully loaded, so an
    answering /slots means loaded:true; the list itself counts busy slots
    (both spellings across versions: state:"processing" and "processing":true).
    A 404/absent endpoint counts as not-live: the unit runs without --slots
    only if someone broke the run line, which is a bug to surface, not to
    route around."""
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{model['port']}/slots", timeout=timeout
        ) as r:
            slots = json.loads(r.read().decode())
    except Exception:
        return None, None
    if not isinstance(slots, list):
        return None, None
    busy = sum(
        1
        for s in slots
        if isinstance(s, dict)
        and (str(s.get("state", "")).lower() == "processing" or s.get("processing") is True)
    )
    return True, busy


def loaded_of(model):
    """Is this table entry's engine loaded? (serve-up-but-loading -> False for
    strata; the live_model() caller keeps that as a weaker 'best' hint.)"""
    if model.get("kind") == "llama":
        loaded, _ = llama_slots(model)
        return bool(loaded)
    st = status_of(model["port"])
    return bool(st and st.get("loaded"))


def inflight_of(model):
    """Requests the engine is currently answering (best-effort: a probe that
    cannot be parsed counts 0 — the same tolerance the strata path has)."""
    if model.get("kind") == "llama":
        _, busy = llama_slots(model)
        return busy or 0
    st = status_of(model["port"])
    return int(((st or {}).get("activity") or {}).get("in_flight", 0) or 0)


def live_model():
    """The id of the model currently served (loaded > loading > none), or None."""
    best = None
    for m in MODELS:
        if loaded_of(m):
            return m["id"]
        if m.get("kind") == "llama":
            continue  # llama-server is up exactly when it is loaded; no middle state
        if status_of(m["port"]) is not None:
            best = best or m["id"]  # serve is up but the engine is loading/unloaded
    return best


def free_vram_mib():
    try:
        out = subprocess.run(
            ["amd-smi", "metric", "-m", "--json"],
            capture_output=True, text=True, timeout=15,
        ).stdout
        data = json.loads(out)
        # amd-smi 7.2.4 shape: {"gpu_data": [{"mem_usage": {"free_vram":
        # {"value": N, "unit": "MB"}}}]}. The old flat [ {...} ] form stays as
        # a fallback; a miss returns None and the caller skips the gate, which
        # is what silently happened on first deploy — hence this comment.
        item = data["gpu_data"][0]["mem_usage"] if isinstance(data, dict) else data[0]
        return int(item["free_vram"]["value"])
    except Exception:
        return None  # like gpu-mode.sh: skip the VRAM gate if amd-smi cannot answer


def _is_probe(body_bytes):
    """True for a liveness/readiness completion: tiny prompt AND tiny answer.

    Such requests must never cost a swap (a health check naming the "other"
    model would otherwise stop the live engine and reload a tens-of-GB model
    to emit one token). serve's /v1/chat/completions answers a foreign `model`
    name with whatever is loaded, so forwarding it to the live engine IS the
    nod. Deliberately conservative: anything with real content, tools, or a
    real answer budget is not a probe and takes the normal swap path."""
    if not body_bytes:
        return False
    try:
        b = json.loads(body_bytes.decode("utf-8", "replace"))
    except Exception:
        return False
    mt = b.get("max_tokens", b.get("max_completion_tokens"))
    if not isinstance(mt, int) or isinstance(mt, bool) or mt > PROBE_MAX_TOKENS:
        return False
    if b.get("tools"):
        return False
    msgs = b.get("messages")
    if not isinstance(msgs, list) or not msgs:
        return False
    chars = 0
    for m in msgs:
        c = m.get("content") if isinstance(m, dict) else None
        if isinstance(c, str):
            chars += len(c)
        elif isinstance(c, list):
            for p in c:
                if not isinstance(p, dict) or p.get("type", "text") != "text":
                    return False  # images/other parts: not a probe
                chars += len(p.get("text") or "")
        elif c is not None:
            return False  # content parts we do not understand: not a probe
    return chars <= PROBE_MAX_CHARS


def systemctl(action, unit):
    subprocess.run(["systemctl", action, unit], check=True, capture_output=True, timeout=300)


def wait_loaded(model, timeout_s=1500):
    """Poll until the target engine reports loaded (strata: serve says
    loaded:true; llama: /slots answers — which it only does once the model
    is fully loaded). True/False."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if loaded_of(model):
            return True
        try:
            active = subprocess.run(
                ["systemctl", "is-active", "--quiet", model["unit"]]
            ).returncode == 0
        except Exception:
            active = True
        if not active:
            return False  # unit gave up (condition / crash) — do not wait it out
        time.sleep(5)
    return False


def do_swap(target_id):
    """Stop the live engine, start BY_ID[target_id], wait ready. True on success.

    Called ONLY with swap_lock held and a live model that is not target_id.
    Every systemctl failure lands on the 503/rollback path, never a traceback:
    a failure BEFORE the stop touched anything needs no rollback; after the
    start attempt we put the old unit back."""
    target = BY_ID[target_id]
    cur_id = live_model()
    if cur_id is None:
        return None  # not ours to start (see the lease invariant)
    if cur_id == target_id:
        return True  # someone else already made the swap while we queued
    cur = BY_ID[cur_id]
    # Never pull the model out from under a running request: the other client's
    # turn would be killed mid-stream (which is what made the card feel like it
    # "kept restarting"). Wait for it to drain; if it is still busy at the
    # deadline, answer 409 and leave it alone — a single-slot engine queues,
    # it does not cancel.
    deadline = time.monotonic() + DRAIN_SECS
    waited = False
    while time.monotonic() < deadline:
        busy = inflight_of(cur)
        if busy <= 0:
            break
        if not waited:
            log(f"WAIT {cur_id}: {busy} request(s) in flight; swapping to {target_id} "
                f"when it finishes (max {DRAIN_SECS}s)")
            waited = True
        time.sleep(2)
    else:
        if DRAIN_SECS > 0:
            busy = inflight_of(cur)
            if busy > 0:
                log(f"BUSY {cur_id}: {busy} request(s) still in flight after {DRAIN_SECS}s; "
                    f"not swapping to {target_id}")
                return "busy"
    log(f"SWAP {cur_id} -> {target_id} (unit {target['unit']})")
    t0 = time.monotonic()
    try:
        systemctl("stop", cur["unit"])
    except Exception as e:
        log(f"stop {cur['unit']} failed: {e}; the live model stays put")
        return False
    need = int(target.get("vram_min_mib", 0))
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        free = free_vram_mib()
        if free is None or free >= need:
            break
        time.sleep(2)
    else:
        log(f"VRAM did not reach {need} MiB free; starting anyway (before_load may stop sd-server)")
    started = True
    try:
        systemctl("start", target["unit"])
    except Exception as e:
        log(f"start {target['unit']} failed: {e}")
        started = False
    if started and wait_loaded(target):
        log(f"swap done in {time.monotonic() - t0:.0f}s: {target_id} loaded")
        return True
    log(f"FAILED to bring up {target_id}; rolling {cur_id} back")
    try:
        systemctl("start", cur["unit"])
    except Exception as e:
        log(f"rollback start of {cur['unit']} failed too: {e}")
    return False


def route(target_id):
    """Resolve a request for `target_id` to a live engine port, or (None, 503 body)."""
    live = live_model()
    if live is None:
        return None, {
            "error": {
                "type": "unavailable",
                "message": "no Strata engine is running: the R9700 is off the llm lease "
                "— run `gpu-mode llm` on zen3-nixos (the shim never starts a model itself)",
            }
        }
    if live != target_id and target_id in BY_ID:
        with swap_lock:
            ok = do_swap(target_id)
        if ok is None:
            return None, {"error": {"type": "unavailable", "message": "the card went idle mid-swap"}}
        if ok == "busy":
            return None, {
                "_status": 409,
                "error": {
                    "type": "conflict",
                    "message": f"{BY_ID[live]['id']} is still answering a request; retry to switch to "
                    f"{target_id} when it finishes (nothing was stopped)",
                }
            }
        if not ok:
            return None, {
                "error": {
                    "type": "server_error",
                    "message": f"swap to {target_id} failed and {BY_ID[live]['id']} was restarted; "
                    f"journalctl -u {BY_ID[live]['unit']} -u {BY_ID[target_id]['unit']}",
                }
            }
    return BY_ID[target_id]["port"], None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "strata-swap/1"

    def _send(self, code, body: bytes, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode())

    def _advertise(self):
        """GET /v1/models: both families, llama-router-style (unloaded = loads on use)."""
        data, seen = [], set()
        live = live_model()
        for m in MODELS:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{m['port']}/v1/models", timeout=4) as r:
                    theirs = json.loads(r.read().decode()).get("data", [])
                for d in theirs:
                    if d.get("id") not in seen:
                        seen.add(d.get("id"))
                        data.append(d)
            except Exception:
                pass
            if m["id"] not in seen:
                seen.add(m["id"])
                data.append({"id": m["id"], "object": "model",
                             "status": {"value": "unloaded" if m["id"] != live else "loaded"}})
        self._json(200, {"object": "list", "data": data,
                         "swap": {"live": live, "default": BOOT}})

    def _status_stub(self):
        """GET /v1/status with nothing live: gpu-mode.sh's json_field still parses this."""
        self._json(503, {"service": "strata-swap", "model": None, "loaded": False,
                         "auto_load": False, "models": [m["id"] for m in MODELS],
                         "hint": "gpu-mode llm"})

    CLIENT_POLL = 0.5  # seconds between downstream EOF checks

    def _client_gone(self):
        """True when the downstream peer has closed its end of the connection.

        `select` marks a socket readable on EOF (FIN) and MSG_PEEK then returns
        b"" without consuming anything. Unexpected early data is NOT treated as
        gone (a pipelining client is merely ignored)."""
        try:
            r, _, _ = select.select([self.connection], [], [], 0)
            if not r:
                return False
            return self.connection.recv(1, socket.MSG_PEEK) == b""
        except (OSError, ValueError):
            return True

    def _proxy(self, method, body=None):
        """Stream through to `self.upstream_port` (chunk-by-chunk: SSE included),
        and CANCEL the upstream the moment the downstream client disappears.

        A prefill can run for many minutes before the first response byte
        exists, so a blocking read can never notice a dead client: the request
        then runs to completion into a socket nobody is reading (measured
        2026-11-23 — a 102K prefill kept grinding for 8 min after its clients
        were cut off at the firewall). So the upstream leg runs in a worker
        thread and this thread watches the client socket; on EOF we close the
        upstream connection, which is how llama-server is told the client is
        gone ("client disconnected") and stops the request dead.

        Framing: http.client already decoded any chunked encoding, and we do
        not re-chunk — so the proxied response is NOT keep-alive: the close is
        the framing when there is no Content-Length (and nginx copes with
        close-delimited upstreams fine; it is itself a fresh downstream
        connection per request either way)."""
        self.close_connection = True
        cancelled = threading.Event()
        state = {"conn": None}

        def upstream():
            conn = None
            try:
                conn = http.client.HTTPConnection("127.0.0.1", self.upstream_port, timeout=3700)
                state["conn"] = conn
                if cancelled.is_set():
                    return
                conn.request(method, self.path, body=body, headers=self._headers())
                resp = conn.getresponse()
                if cancelled.is_set():
                    return
                self.send_response(resp.status, resp.reason)
                for k, v in resp.getheaders():
                    if k.lower() not in HOP_BY_HOP:
                        self.send_header(k, v)
                self.end_headers()
                while not cancelled.is_set():
                    chunk = resp.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass  # client hung up mid-stream; the watcher logs the cancel
            except Exception as e:
                if not cancelled.is_set():
                    log(f"proxy {method} {self.path} -> :{self.upstream_port} failed: {e}")
                    try:
                        self._json(502, {"error": {"type": "bad_gateway", "message": f"strata-swap: {e}"}})
                    except Exception:
                        pass
            finally:
                if conn is not None:
                    try:
                        conn.close()
                    except Exception:
                        pass

        t = threading.Thread(target=upstream, daemon=True)
        t.start()
        while t.is_alive():
            if self._client_gone():
                cancelled.set()
                conn = state["conn"]
                if conn is not None:
                    # shutdown(), not close(): close() on a socket whose fd is
                    # held by the worker's blocked read sends no FIN at all, so
                    # the engine never learns. shutdown() emits it immediately.
                    usock = getattr(conn, "sock", None)
                    if usock is not None:
                        try:
                            usock.shutdown(socket.SHUT_RDWR)
                        except Exception:
                            pass
                    try:
                        conn.close()
                    except Exception:
                        pass
                log(f"CANCEL {method} {self.path} -> :{self.upstream_port} (client gone)")
                return
            t.join(self.CLIENT_POLL)

    def _headers(self):
        h = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        # Forward the ORIGINAL Host: IP hosts always pass serve's rebinding guard and
        # the public names are in allowed_hosts (serve/server.py host_allowed()).
        return h

    def _pick_target(self, body_bytes):
        """The model a request asks for, exactly; anything unknown/absent -> live/BOOT."""
        if not body_bytes:
            return None
        try:
            asked = json.loads(body_bytes.decode("utf-8", "replace")).get("model")
        except Exception:
            return None
        return asked if isinstance(asked, str) and asked in BY_ID else None

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/v1/models":
            return self._advertise()
        live = live_model()
        if live is None:
            if path == "/v1/status":
                return self._status_stub()
            return self._json(503, {"error": {"type": "unavailable", "message": "the LLM lease is off: gpu-mode llm"}})
        if path == "/v1/status" and BY_ID[live].get("kind") == "llama":
            # Synthesize the strata-dialect /v1/status: llama-server has no
            # such endpoint (a proxy pass would 404), and gpu-mode.sh's
            # json_field(loaded/in_flight/model) on :8080 must keep reading
            # the truth for whichever engine is live.
            _, busy = llama_slots(BY_ID[live])
            return self._json(200, {
                "service": "strata-swap", "engine": "llama.cpp", "model": live,
                "loaded": True, "in_flight": busy or 0, "auto_load": False,
                "models": [m["id"] for m in MODELS],
            })
        self.upstream_port = BY_ID[live]["port"]
        return self._proxy("GET")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        n = int(self.headers.get("Content-Length") or 0)
        if n > 64 * 1024 * 1024:
            return self._json(413, {"error": {"type": "invalid_request", "message": "strata-swap: body too large"}})
        body = self.rfile.read(n) if n else b""
        target = self._pick_target(body) if path in MODEL_BODY_PATHS else None
        if target is not None and _is_probe(body):
            # "Are you still there?" is answered by whatever is live: a reload
            # (tens of GB, tens of seconds) to emit one token is pure waste, and
            # it would stop another client's turn. serve answers a foreign
            # `model` name with the loaded engine — this is the nod.
            live_now = live_model()
            if live_now is not None and live_now != target:
                log(f"NOD {target} -> {live_now} (probe: {n} body bytes; no swap)")
            target = None
        if target is None:
            live = live_model()
            if live is None:
                return self._json(503, {"error": {"type": "unavailable", "message": "the LLM lease is off: gpu-mode llm"}})
            port, err = BY_ID[live]["port"], None
        else:
            port, err = route(target)
        if err:
            return self._json(err.pop("_status", 503), err)
        self.upstream_port = port
        return self._proxy("POST", body)

    do_PUT = do_POST  # serve has none today; treat like POST for completeness

    def log_message(self, fmt, *args):  # quiet: swaps log themselves, request noise does not
        pass


if __name__ == "__main__":
    # systemctl/amd-smi come from the unit's `path` (systemd + amd-smi). They
    # are only WARNINGS at start: amd-smi failing at boot is a reason to skip
    # the VRAM gate (free_vram_mib -> None), not to leave :8080 unbound.
    for u in ("systemctl", "amd-smi"):
        if not shutil.which(u):
            log(f"WARNING: {u} not on PATH; swaps needing it will fail (check the unit's path=)")
    log(f"listening on 127.0.0.1:{LISTEN_PORT}; models: "
        + ", ".join(f"{m['id']} -> :{m['port']} ({m['unit']})" for m in MODELS))
    ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Handler).serve_forever()
