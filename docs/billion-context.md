# billion-context (context-compression proxy) — config & tuning

`billion-context` is the proxy sitting between the coding agent and the model
that provides the ACP compression tools (`compress` / `decompress` /
`search_context` / `acp_status` / `acp_cache`) and decides **when** to fold
(compact) the conversation. It is the thing that emits the
`📦 [ACP] Compressed …` markers and the soft nudges telling the agent to
compact.

This doc records how it works, why folds were happening at ~50 % of a 256K
window, and the tuning applied on 2026-09-30.

## Where everything lives

| What | Path |
| --- | --- |
| Package | `/home/cjdell/.local/lib/node_modules/billion-context` (version `0.1.175`) |
| Config | `~/.config/billion-context/billion-context.json` |
| Config reference (not shipped with npm) | `https://raw.githubusercontent.com/ranxianglei/billion-context/master/CONFIGURATION.md` |
| Log | `~/.local/state/billion-context/bili.log` (rotates at 10 MB → `bili.log.old`) |
| Session state | `~/.local/share/billion-context/sessions/openai/<host>_<hash>.json` |
| Web UI / session browser | `http://127.0.0.1:18787/__bili/#/` |

Run command (from the running process): `node .../billion-context/dist/index.js
start --host 127.0.0.1 --port 18787`. Management endpoints are loopback-only:
`/__bili/config`, `/__bili/config/reload` (POST), `/__bili/health`,
`/__bili/logs`, `/__bili/overview`, `/__bili/sessions`, `/__bili/stats`,
`/__bili/status`, `/__bili/upstream`, `/__bili/watcher`, `/__bili/plugin/*`.

**There is no per-session detail REST endpoint** — `/__bili/sessions` lists
sessions and the session JSON on disk is the source of truth for the effective
config/blocks.

There is **no file watch**: editing the config does nothing until
`POST /__bili/config/reload` (or a restart). No `--impure`/Nix involved — this
is a plain user-local npm install, not a NixOS module.

## The compression config model

Three-level merge, deeper wins per field (an unset field at a deeper level never
clears the higher one):

```
global top-level "compress"
  → providers["<base-url>"].compress
    → providers["<base-url>"].models["<model>"].compress
```

Only the **global** level honours `injectTool` / `injectNudge`.

Key knobs and defaults:

| Key | Default | Meaning |
| --- | --- | --- |
| `modelContextLimit` | model native window | context window used as the denominator for the usage ratio and as the hard preflight wall. Not a truncation cap. |
| `outputHeadroomMaxPct` | `0.25` | reserved = `min(max_tokens, pct × window)`; effective window = window − reserved. `0` disables the reservation; `>=1` restores the legacy full reservation. Anthropic Messages is exempt. |
| `maxContextLimit` | `"75%"` | forced-compression nudge threshold, as a % of the **effective** window. Bypasses the growth gate. |
| `emergencyThresholdPercent` | `"95%"` | emergency truncation. Must be ≥ `maxContextLimit`. |
| `nudgeGrowthTokens` | `50000` | soft-nudge growth step: a nudge fires every ~this many tokens of newly-compressible content. Flattens the engine's adaptive growth band to a fixed step (sets both `growthFloor` and `growthCap`). |
| `preserveRecentMessages` | ~`5` | recent messages always kept out of a fold. |
| `preserveRecentTokens` | ~`5000` | recent tokens always kept. |
| `minCompressRangeChars` (legacy `minCompressRange`) | kernel default | minimum fold range in **characters**, not tokens. |

Other fields: `tiers` (tier2Trigger 1000 / tier3Trigger 2000), `protectedTools`,
`protectedLatestTools`, `neverPreserveRecentTools` (built-in
`["decompress","search_context","read","bash"]`), `preserveRecentTools`,
`prompts` / `promptPack` (`default`, `lean`), `absorb`, `ccr`, `search`,
`imageCompression` (off by default), `rules` (off by default).

## The actual bug/behaviour: folds at ~50 % usage

Session `01a0f1b7-c26a-74f5-907f-0df729f83c6f` (pi agent, model
`Qwen3.8-27B-UD-Q5_K_XL`, native 262144 served by llama-swap `ctx-size`) folded
28 times in ~3 h. Every fold log line looked like:

```
nudge INJECT T1: usage=54% (106053/196608), pendingT1=50075/50000,
  interval=50000, reason="T1 effective 50075 >= 50000, growth 41137, usage 54%"
```

Two independent reasons the window was never used:

1. **The soft nudge keys off accumulated compressible tokens, not usage.** It
   fires when `pendingT1 >= nudgeGrowthTokens` (50000), regardless of how big
   the window is. That is why folds happened at 47–70 % — the real trigger was
   "50K of new content became compressible", not "we're near the limit".
2. **`outputHeadroomMaxPct=0.25` shrank the window.** With
   `outputBudgetHighWater=148495`, reserve = `min(148495, 0.25 × 262144)` =
   65536 → `effectiveContextLimit = 196608`. So `maxContextLimit=75%` was
   actually 147456 = **56 % of the true 256K** — and it never even fired,
   because the 50K growth nudge always beat it.

Usage ratios are computed against the **effective** window (196608), so a
reported "54 %" was ~40 % of the real 262144.

## Fix applied (2026-09-30)

`~/.config/billion-context/billion-context.json`:

```json
{
  "providers": {},
  "compress": {
    "outputHeadroomMaxPct": 0.125,
    "maxContextLimit": "90%",
    "emergencyThresholdPercent": "95%",
    "nudgeGrowthTokens": 100000
  }
}
```

| | before | after |
| --- | --- | --- |
| effective window | 196608 | 229376 |
| soft nudge fires every | 50K compressible tokens | 100K |
| hard force threshold | 147456 (56 % native) | 206438 (79 % native) |

Applied with `curl -X POST http://127.0.0.1:18787/__bili/config/reload`
(returns `{"ok":true,...}`); verify with `GET /__bili/config`. The change takes
effect on the next request, not mid-session.

Backup of the pre-change file:
`~/.config/billion-context/billion-context.json.bak.20260930-144917` (the old
file was just `{ "providers": {} }`, i.e. all defaults).

Net effect: roughly **half the fold frequency**, and the hard ceiling moved from
56 % to 79 % of the native window.

## Further tuning levers

- **Push toward ~90 % native:** `outputHeadroomMaxPct: 0.0625` (16K reserve) →
  effective 245760; with `maxContextLimit: "90%"` → 221184 = 84 % native. The
  model averages ~1.6K output tokens here, so 16K is generous; the risk is a
  rare long generation overflowing once, which bili self-heals next turn.
- **Fewer soft folds still:** `nudgeGrowthTokens: 128000`.
- **Per-model tuning:** put a `compress` block under
  `providers[url].models[model].compress`. A flat 100K growth step is very
  conservative for a 1M-token model (`deepseek-flash` had `native=1000000`) and
  would fold it early — give it its own block if it gets heavy use.
- **`maxContextLimit` is a nudge, not a cap.** The hard wall is
  `emergencyThresholdPercent`; keep a gap between them (the config rejects
  `emergency < maxContextLimit`).
- **RAM:** on zen3-nixos the r9700 router runs `-cram 32768` and a larger
  `modelContextLimit` means more context/KV memory in play — mind the OOM
  behaviour documented in `AGENTS.md`.

## Verification quickies

```sh
# live config the proxy is using
curl -s http://127.0.0.1:18787/__bili/config | head -c 2000

# what triggered each fold (uses the ratio key + reason string)
grep -E "nudge INJECT" ~/.local/state/billion-context/bili.log | tail -20

# what window the proxy computed for a model
grep "\[window\]" ~/.local/state/billion-context/bili.log | tail

# reload after editing the config
curl -s -X POST http://127.0.0.1:18787/__bili/config/reload
```

Note: this `billion-context` proxy is a **separate thing from pi's own
auto-compaction**. The folds/`📦 [ACP]` markers in an agent session come from
this proxy, and tuning it here is what changes their frequency.
