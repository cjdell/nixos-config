#!/usr/bin/env python3
"""Recorder for the Inkling lane's decode collapses (the "0.2 tok/s" class).

Why this exists: the 2026-11-24 collapse was reconstructed after the fact from
systemd logs and a ring buffer that keeps only 12 requests, so the one thing
that mattered -- *which* request was resident next to which, and whether either
of them reused a prefix -- was gone by the time anyone looked. This samples the
engine's own ledger so the next occurrence is read, not inferred.

It is passive: GETs only (/metrics, /slots), one amd-smi every sample when a
trigger fires, and journal/nginx tails in the dump. Nothing touches the engine.

Triggers (all deduped per kind, DEDUP_S between dumps):
  two-active   live.running >= 2 -- more than one slot processing. This is the
               over-commitment that costs 212K tokens of K/V against a 163,840
               carve; it does not need to be slow to be worth recording.
  slow-decode  a request generating below SLOW tok/s for SLOW_SAMPLES samples.
  stalled      generating with the same prompt_tokens/generated for ~60 s.

Usage:
  inkling-collapse-sampler.py [--out DIR] [--interval S] [--self-test]
Run it as root (journal + the nginx access log are root-readable).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timedelta

PORT = 8094
OUT_DIR = "/var/lib/inkling/collapse"
INTERVAL = 5.0
SLOW = 5.0
SLOW_SAMPLES = 2
STALL_S = 60.0
RING = 180  # 15 min at the default interval
KEEP = 20
DEDUP_S = 120.0
HEARTBEAT_S = 300.0

JOURNALCTL = "/run/current-system/sw/bin/journalctl"
AMD_SMI = ("/run/current-system/sw/bin/amd-smi", "amd-smi")
NGINX_LOG = "/var/log/nginx/access.log"


def now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def get_json(path, timeout=5):
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=timeout) as r:
        return json.loads(r.read().decode())


def run(args, timeout=15):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else f"<rc={p.returncode}> {p.stderr.strip()[:400]}"
    except Exception as e:  # noqa: BLE001 - diagnostics must never raise
        return f"<{type(e).__name__}: {e}>"


def amd_smi():
    for exe in AMD_SMI:
        out = run([exe, "metric", "-m", "--json"], timeout=12)
        if out.startswith("{"):
            try:
                return json.loads(out)
            except json.JSONDecodeError:
                pass
    return None


def vram():
    """The few numbers worth keeping from amd-smi's fairly large JSON."""
    d = amd_smi()
    if not d:
        return None
    try:
        m = d["gpu_data"][0]["mem_usage"]
        return {
            "used_vram_mib": m["used_vram"]["value"],
            "free_vram_mib": m["free_vram"]["value"],
            "used_gtt_mib": m["used_gtt"]["value"],
        }
    except (KeyError, IndexError, TypeError):
        return None


def sample():
    s = {"ts": round(time.time(), 3), "iso": now_iso()}
    try:
        m = get_json("/metrics")
        live = m.get("live") or {}
        cc = m.get("conversation_cache") or {}
        hw = m.get("hardware") or {}
        s.update(
            state=live.get("state"),
            running=live.get("running"),
            queued=live.get("queued"),
            waiting=live.get("waiting"),
            tok_s=live.get("tok_s"),
            elapsed_s=live.get("elapsed_s"),
            prompt_tokens=live.get("prompt_tokens"),
            reused=live.get("reused"),
            generated=live.get("generated"),
            slots=live.get("slots"),
            parks=cc.get("parks"),
            restores=cc.get("restores"),
            evictions=cc.get("evictions"),
            gpu_util=hw.get("gpu_util"),
            gpu_power=hw.get("gpu_power"),
        )
    except Exception as e:  # noqa: BLE001
        s["error"] = f"{type(e).__name__}: {e}"
    return s


def nginx_posts(minutes=20):
    """The POST lines that name the client requests in the window."""
    try:
        with open(NGINX_LOG, "r", errors="replace") as f:
            tail = f.readlines()[-4000:]
    except OSError as e:
        return f"<{e}>"
    cutoff = datetime.now().astimezone() - timedelta(minutes=minutes)
    keep = []
    pat = re.compile(r"\[([^\]]+)\]")
    for line in tail:
        if "POST " not in line:
            continue
        m = pat.search(line)
        if not m:
            continue
        try:
            ts = datetime.strptime(m.group(1), "%d/%b/%Y:%H:%M:%S %z")
        except ValueError:
            continue
        if ts >= cutoff:
            keep.append(line.rstrip()[:400])
    return keep


def dump(kind, ring, reason, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    rec = {
        "trigger": kind,
        "reason": reason,
        "at": now_iso(),
        "engine": {"port": PORT},
        "ring": list(ring),
        "vram_now": vram(),
    }
    try:
        rec["metrics"] = get_json("/metrics", timeout=8)
    except Exception as e:  # noqa: BLE001
        rec["metrics_error"] = f"{type(e).__name__}: {e}"
    try:
        rec["slots"] = get_json("/slots")
    except Exception as e:  # noqa: BLE001
        rec["slots_error"] = f"{type(e).__name__}: {e}"
    rec["ss_8094"] = run(["/run/current-system/sw/bin/ss", "-tnp"]).splitlines()
    rec["ss_8094"] = [l for l in rec["ss_8094"] if ":8094" in l or ":8080" in l]
    rec["journal_inkling"] = run([JOURNALCTL, "-u", "inkling-2-mini", "-n", "300", "--no-pager"])
    rec["journal_swap"] = run([JOURNALCTL, "-u", "strata-swap", "-n", "120", "--no-pager"])
    rec["nginx_posts"] = nginx_posts()

    name = f"{datetime.now().strftime('%Y%m%dT%H%M%S')}-{kind}.json"
    path = os.path.join(out_dir, name)
    with open(path, "w") as f:
        json.dump(rec, f, indent=1)
    # keep the newest KEEP dumps
    have = sorted(
        (p for p in os.listdir(out_dir) if p.endswith(".json")),
        key=lambda p: os.path.getmtime(os.path.join(out_dir, p)),
    )
    for old in have[:-KEEP]:
        try:
            os.unlink(os.path.join(out_dir, old))
        except OSError:
            pass
    print(f"strata-sampler: DUMP {kind} -> {path} ({reason})", flush=True)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT_DIR)
    ap.add_argument("--interval", type=float, default=INTERVAL)
    ap.add_argument("--slow", type=float, default=SLOW)
    ap.add_argument("--self-test", action="store_true", help="one sample + one dump, then exit")
    args = ap.parse_args()

    if args.self_test:
        s = sample()
        print("strata-sampler: sample " + json.dumps(s), flush=True)
        dump("self-test", [s], "self-test", args.out)
        return 0

    ring = []
    last = {}  # kind -> monotonic time of the last dump
    slow_hits = 0
    last_progress = None  # (prompt_tokens, generated, monotonic) for the stall trigger
    last_beat = 0.0
    print(
        f"strata-sampler: watching :{PORT} every {args.interval:g}s, out={args.out}, "
        f"slow<{args.slow:g}tok/s, dumps on two-active/slow/stall",
        flush=True,
    )

    while True:
        s = sample()
        ring.append(s)
        if len(ring) > RING:
            del ring[:-RING]
        mono = time.monotonic()
        triggers = []

        if s.get("running", 0) and s["running"] >= 2:
            live = [x for x in (s.get("slots") or []) if x.get("state") not in (None, "idle")]
            triggers.append(
                ("two-active", f"running={s['running']} slots=" + json.dumps(
                    [{k: x.get(k) for k in ("slot", "state", "held_tokens", "prompt_tokens", "generated")} for x in live]
                ))
            )

        if s.get("state") == "generating" and isinstance(s.get("tok_s"), (int, float)) and s["tok_s"] < args.slow:
            slow_hits += 1
            if slow_hits >= SLOW_SAMPLES:
                triggers.append(("slow-decode", f"tok_s={s['tok_s']} for {slow_hits} samples, prompt={s.get('prompt_tokens')}"))
        else:
            slow_hits = 0

        if s.get("state") == "generating":
            key = (s.get("prompt_tokens"), s.get("generated"))
            if last_progress and last_progress[0] == key and mono - last_progress[1] >= STALL_S:
                triggers.append(("stalled", f"no progress for {mono - last_progress[1]:.0f}s at prompt={key[0]} generated={key[1]}"))
                last_progress = (key, mono)  # re-arm rather than spam
            elif not last_progress or last_progress[0] != key:
                last_progress = (key, mono)
        else:
            last_progress = None

        for kind, reason in triggers:
            if mono - last.get(kind, -1e9) < DEDUP_S:
                continue
            last[kind] = mono
            try:
                dump(kind, ring, reason, args.out)
            except Exception as e:  # noqa: BLE001
                print(f"strata-sampler: dump failed: {type(e).__name__}: {e}", flush=True)

        if mono - last_beat >= HEARTBEAT_S:
            last_beat = mono
            print(
                "strata-sampler: alive "
                f"state={s.get('state')} running={s.get('running')} tok_s={s.get('tok_s')} "
                f"prompt={s.get('prompt_tokens')} queued={s.get('queued')} dumps={sum(1 for k in last if k)}",
                flush=True,
            )

        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
