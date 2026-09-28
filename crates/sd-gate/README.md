# sd-gate

On-demand launcher + TCP proxy for `sd-server` (stable-diffusion-cpp), with a
status page and a VRAM guard.

VRAM on the R9700 is shared with llama-swap's resident coding model (~26 GB of
32 GB), so SDXL should not sit in VRAM when it isn't being used. `sd-gate`:

- always listens on `127.0.0.1:8084` (nginx's `/sd-api/` target);
- on the **first connection** spawns the child command (sd-server on
  `127.0.0.1:8085`), waits for readiness (`GET /v1/models` → HTTP 200), then
  relays TCP traffic bidirectionally;
- before spawning, checks free VRAM via `--vram-tool` (`amd-smi
  metric -m --json`): if less than `--min-vram-gib` (default 10) is free —
  i.e. the llama-swap LLM is resident — it posts to `--llm-unload-url`
  (llama-swap's `POST /api/models/unload`) and waits up to `--vram-wait-secs`
  (default 90) for the VRAM to be released. If it stays low it proceeds
  anyway (SD runs at GTT-spill speed rather than refusing to run). The LLM
  loads back on the next LLM request;
- after `--idle` seconds (default 120) with no connections, **kills the
  child** — the model is out of VRAM. The next request loads it back (tens of
  seconds);
- serves a status page on `127.0.0.1:8086` (nginx:
  `http://192.168.49.50/sd-status/`): an HTML dashboard at `/` and hand-built
  JSON at `/status`. Shows state (idle/starting/ready/stopping), sd-server
  pid/times, the idle-unload countdown, VRAM, and **active clients** — remote
  IP (nginx's `X-Forwarded-For`), request, age, phase — i.e. why the model is
  currently loaded and not shut down. The status listener never spawns the
  server, so watching it has no side effect.

Zero dependencies: Rust std only (two libc symbols via `extern "C"`), built
by `hosts/zen3-nixos/ai.nix` into the `sd-gate` systemd service.

Flags:

```
sd-gate [--listen ADDR]            # default 127.0.0.1:8084
        [--status-listen ADDR]     # default 127.0.0.1:8086 ("" disables)
        [--upstream ADDR]          # default 127.0.0.1:8085
        [--idle SECS]              # default 120
        [--ready-timeout SECS]     # default 180
        [--vram-tool PATH]         # default amd-smi
        [--min-vram-gib N]         # default 10
        [--llm-unload-url URL]     # default http://127.0.0.1:8081/api/models/unload ("" disables)
        [--vram-wait-secs N]       # default 90
        -- <sd-server command>
```

Manual controls:

- force-unload now: `kill $(cat /run/sd-gate.pid)`
- watch the lifecycle: `journalctl -u sd-gate -f`
- VRAM check: `amd-smi metric -m --json`
