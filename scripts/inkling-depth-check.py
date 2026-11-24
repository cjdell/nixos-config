#!/usr/bin/env python3
"""Depth probe for the inkling-2-mini lane (:8094).

Builds a cold prompt of ~N tokens (unique filler, so nothing is cached), puts a
needle in it, and reports what the lane actually did: prompt tokens, prompt_ms,
reused, first-token latency, decode t/s, and whether the needle came back.

    python3 ink-depth-check.py 110000
    python3 ink-depth-check.py 110000 --warm     # second turn: +1 line, tests reuse

Why this exists: on 2026-11-24 the lane's failure mode was a read that
*finished* and then produced no first token for 300 s (GPU 100 %, 145 W, one CPU
core pegged) - invisible to a plain curl with a long timeout, so every probe
prints progress on the way to the first byte.
"""
import argparse
import json
import sys
import threading
import time
import urllib.request

BASE = "http://127.0.0.1:8094"
NEEDLE = "The vault code is ZX81-QQ-42."
QUESTION = "What is the vault code? Reply with the code only."


def get(path, timeout=10):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        return json.load(r)


def build(n_tokens, salt):
    # Each line is "line N word0 word1 … word9" — measured at ~33 tokens a line on
    # this tokenizer (an earlier 14-token estimate built a 258,377-token prompt for a
    # 110,000 target and got the server's "exceeds the context window" 400).  Every
    # line is unique, so no prefix of this prompt is cached.
    words = (
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod "
        "tempor incididunt ut labore et dolore magna aliqua enim ad minim veniam"
    ).split()
    lines, i, est = [f"[probe {salt}] {NEEDLE}"], 0, 0
    while est < n_tokens:
        chunk = " ".join(f"{w}{i % 97}" for w in words[:10])
        lines.append(f"line {i} {chunk}")
        est += 33
        i += 1
    lines.append(f"[probe {salt}] end of notes.")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tokens", type=int)
    ap.add_argument("--warm", action="store_true", help="append one line to the previous prompt (prefix reuse)")
    ap.add_argument("--max-tokens", type=int, default=32)
    ap.add_argument("--timeout", type=float, default=900)
    a = ap.parse_args()

    salt = "warm" if a.warm else f"cold{int(time.time())}"
    text = build(a.tokens, salt)
    if a.warm:
        text += "\nline extra follow-up marker 1"

    body = {
        "model": "inkling-2-mini-ud-q4_k_xl",
        "messages": [{"role": "user", "content": text + "\n\n" + QUESTION}],
        "max_tokens": a.max_tokens,
        "temperature": 0.2,
        "stream": False,
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        BASE + "/v1/chat/completions", data=data, headers={"Content-Type": "application/json"}
    )

    result = {}


    def worker():
        try:
            t0 = time.time()
            with urllib.request.urlopen(req, timeout=a.timeout) as r:
                result["body"] = json.load(r)
            result["wall"] = time.time() - t0
        except urllib.error.HTTPError as e:  # surface the server's own message, not just "400"
            try:
                result["error"] = f"HTTP {e.code}: {e.read().decode(errors='replace')[:500]}"
            except Exception:  # noqa: BLE001
                result["error"] = f"HTTP {e.code}"
        except Exception as e:  # noqa: BLE001 - report, do not crash the probe
            result["error"] = repr(e)


    th = threading.Thread(target=worker, daemon=True)
    th.start()
    t0 = time.time()
    last = ""
    while th.is_alive():
        time.sleep(5)
        try:
            m = get("/metrics", timeout=5)["live"]
            row = f"state={m.get('state')} read={m.get('prompt_read')}/{m.get('prompt_tokens')} gen={m.get('generated')} tok_s={m.get('tok_s')}"
        except Exception as e:  # noqa: BLE001
            row = f"metrics unavailable: {e!r}"
        if row != last:
            print(f"[{time.time() - t0:7.1f}s] {row}", flush=True)
            last = row
    th.join()

    print()
    if "error" in result:
        print(f"FAILED after {time.time() - t0:.1f}s: {result['error']}")
        return 1
    try:
        req_row = (get("/metrics")["requests"] or [{}])[0]
    except Exception:  # noqa: BLE001
        req_row = {}
    b = result["body"]
    msg = (b.get("choices") or [{}])[0].get("message", {})
    content = (msg.get("content") or "").strip()
    reasoning = (msg.get("reasoning_content") or "").strip()
    usage = b.get("usage", {})
    print(json.dumps({
        "wall_s": round(result["wall"], 1),
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "reused": req_row.get("reused"),
        "prompt_ms": req_row.get("prompt_ms"),
        "finish_reason": (b.get("choices") or [{}])[0].get("finish_reason"),
        "needle_ok": "ZX81-QQ-42" in (content + reasoning),
        "content_head": content[:160],
        "reasoning_head": reasoning[:160],
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
