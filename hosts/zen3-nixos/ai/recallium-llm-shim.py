#!/usr/bin/env python3
"""Add chat_template_kwargs.enable_thinking = false to Recallium's LLM calls.

Why this exists (measured 2026-11-17, see docs/recallium.md "Insight pipeline"):

  Recallium's nightly insight pipeline and its memory enrichment both call
  /v1/chat/completions with max_tokens=2000. Strata's "answer_room" feature
  carves most of that budget out for the thinking channel:

      thinking limited to 1488 of max_tokens 2000 so the answer has room

  so the model thinks for ~1488 tokens, gets ~512 for a JSON answer, is cut
  off mid-object and finishes with reason=length. Recallium then feeds the
  truncated object to json_repair and stores the patched result: 25 of 25
  truncated calls needed repair on the 2026-11-17 run, ~87 s each.

  The 2000 is compiled into the container (analysis_executor.cpython-313-*.so,
  PROTECTED_BUILD=true; /api/config only *displays* prompt_max_tokens), so the
  request body is the only place the problem can be fixed. With thinking off,
  the whole 2000-token budget goes to the answer: complete JSON, no repair,
  and a fraction of the decode time.

This is a transparent HTTP proxy: it rewrites the body of
POST .../chat/completions and streams everything else through untouched
(SSE included), so Recallium keeps talking to the same URL.

Env:
  SHIM_LISTEN_PORT  listen port on 127.0.0.1 (default 8090)
  SHIM_UPSTREAM     host:port of the engine       (default 127.0.0.1:8080)
"""

import http.client
import json
import os
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(os.environ.get("SHIM_LISTEN_PORT", "8090"))
_upstream = os.environ.get("SHIM_UPSTREAM", "127.0.0.1:8080")
UPSTREAM_HOST, UPSTREAM_PORT = _upstream.rsplit(":", 1)
UPSTREAM_PORT = int(UPSTREAM_PORT)

# Never forward these: the connection framing is ours, not the client's.
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


def add_no_think(body):
    """Return (body, rewrote) with enable_thinking forced off."""
    try:
        data = json.loads(body)
    except Exception:
        return body, False
    if not isinstance(data, dict):
        return body, False
    kwargs = data.get("chat_template_kwargs")
    if not isinstance(kwargs, dict):
        kwargs = {}
    if kwargs.get("enable_thinking") is False:
        return body, False
    kwargs["enable_thinking"] = False
    data["chat_template_kwargs"] = kwargs
    return json.dumps(data).encode(), True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "recallium-llm-shim/1"
    # Strata's one slot means a request can sit queued for many minutes
    # behind an interactive turn before it is even prefilled.
    timeout = 3600

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), fmt % args))

    # ---------------------------------------------------------------- proxy
    def _proxy(self):
        started = time.time()
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        # Strata's DNS-rebinding guard matches the Host header against
        # allowed_hosts; the nginx location already rewrites it to the bare
        # loopback name, and http.client would otherwise append :port here.
        headers["Host"] = UPSTREAM_HOST
        rewritten = False
        is_chat = self.path.split("?", 1)[0].rstrip("/").endswith("/chat/completions")
        if is_chat and body:
            body, rewritten = add_no_think(body)
        if body:
            headers["Content-Length"] = str(len(body))

        conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=self.timeout)
        try:
            conn.request(self.command, self.path, body=body or None, headers=headers)
            resp = conn.getresponse()
        except Exception as exc:  # upstream down / refused / timed out
            self.send_error(502, "upstream error: %s" % exc)
            self.log_message("%s 502 %s (%s)", self.command, self.path, exc)
            conn.close()
            return

        no_body = self.command == "HEAD" or resp.status in (204, 304)
        self.send_response_only(resp.status, resp.reason)
        for key, value in resp.getheaders():
            if key.lower() in ("transfer-encoding", "connection", "content-length", "keep-alive"):
                continue
            self.send_header(key, value)
        if not no_body:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        if not no_body:
            sent = 0
            try:
                while True:
                    chunk = resp.read1(8192)
                    if not chunk:
                        break
                    self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                    self.wfile.flush()
                    sent += len(chunk)
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                # The caller gave up (a client timeout); stop reading upstream
                # so the engine is not held for the rest of the generation.
                pass
            except socket.timeout:
                pass
            self.log_message(
                "%s %s -> %s (%s, %dB in, %dB out, %.1fs)",
                self.command,
                self.path,
                resp.status,
                "thinking off" if rewritten else "passthrough",
                len(body),
                sent,
                time.time() - started,
            )
        else:
            self.log_message(
                "%s %s -> %s (%s, %.2fs)",
                self.command,
                self.path,
                resp.status,
                "thinking off" if rewritten else "passthrough",
                time.time() - started,
            )
        conn.close()

    def do_POST(self):
        self._proxy()

    def do_GET(self):
        self._proxy()

    def do_HEAD(self):
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write(
        "recallium-llm-shim: 127.0.0.1:%d -> %s:%d (chat: thinking forced off)\n"
        % (LISTEN_PORT, UPSTREAM_HOST, UPSTREAM_PORT)
    )
    sys.stderr.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
