> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## opencode supervisor plugin (`users/cjdell/opencode/plugins/supervisor.ts`)

A plugin of the auto-context family that lets the **LFM3 lane police the
Strata lane**: it subscribes to opencode's thinking events and intervenes on
long-horizon agent runs so they finish unattended. Live since 2026-11-11.

- **Large-steps-only policy (user-set): a thinking step under 4000 chars
  (~1k tokens) is not supervised at all** — looping risk concentrates in
  steps that balloon; healthy reasoning runs 100–400 tokens. Kills false
  positives and CPU cost on normal reasoning.
- Three gates: **(1) token collapse** — the *live* `session.reasoning.delta`
  stream's unique-char-8-gram ratio drops below 0.01 → `session.interrupt` +
  steer prompt instantly (this is the strata `!`/`索` #606-class stream;
  measured: collapse 0.001 vs repetitive-but-legit 0.04 vs prose 0.98 — the
  0.01 line never fires on healthy output). **(2) verbatim loop** — ≥3
  consecutive similar (word-4gram Jaccard ≥0.6; measured near-dup 0.69,
  progressing 0.06) completed BIG steps → deterministic interrupt (the judge
  never gates this: 14 s of judging = more wasted generation). **(3)
  premature stop** — on `session.idle` read the last assistant message from
  `session.context` (deterministic when unambiguous: silent tool work / big
  think then empty / `rawFinish=length`; LFM3 judge when ambiguous) → queued
  nudge demanding a results report. Budgets: 4 loop + 3 stop nudges/h/session.
- **Judge lanes = fleet-wide, like Strata itself:** `http://127.0.0.1:8086`
  first (zen3), then `http://192.168.49.50/lfm3/v1` via nginx — so every LAN
  host running the plugin gets the identical full behaviour (off-LAN degrades
  to the deterministic gates; rotates lanes on failure, `LFM3_ENDPOINT` pins
  one).
- **Judge reliability: LFM3 JSON prompts need `max_tokens 1200`** — at
  ≤900 it dies `finish=length` with empty `content` (thinking eats it; the
  GGUF template has NO `thinking` kwarg so `thinking:false` is a no-op, and
  `response_format json_object` makes it worse). At 1200: ~14 s, `stop`,
  clean JSON (parse `content` first, `reasoning_content` fallback).
- **Ops traps learned:** opencode's background service has **stdout on
  /dev/null** → plugin logs must go to a file (this one appends
  `~/.local/share/opencode/supervisor.log` — the audit trail for every
  intervention); **v2.2.7 hot-reload re-runs the CACHED module** — plugin
  code changes land on the next service (re)start, so never restart it from
  inside an opencode session (that session dies with it);
  `session.message.content.updated` is in the v2.2.7 OpenAPI schemas but is
  **not a subscribable event type** (server warns and ignores it).

