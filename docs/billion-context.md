# billion-context (context-compression proxy) — config & tuning

`billion-context` is the proxy sitting between the coding agent and the model
that provides the ACP compression tools (`compress` / `decompress` /
`search_context` / `acp_status` / `acp_cache`) and decides **when** to fold
(compact) the conversation. It is the thing that emits the
`📦 [ACP] Compressed …` markers and the soft nudges telling the agent to
compact.

This doc records how it works, why folds were happening at ~50 % of a 256K
window, and the tuning applied on 2026-09-30.

**Status as verified 2026-10-08 (v0.1.188, commit `62598940`):** healthy — one
proxy process (pid 3260) on the **pi lane port 18789**, `stale: false`, 0
`[error]` log lines, 52 sessions / 11 999 requests / 521 folds / 98 % prompt-cache
hit. The 2026-09-30 tuning below is still the live config (effective window
229376 confirmed in the per-session log lines). Everything in this doc that says
port `18787` predates the lane-based port allocation — see *Where everything
lives*.

## Where everything lives

There are **two installs**, and only one of them runs:

| What | Path |
| --- | --- |
| **Running package** (pi-owned) | `/home/cjdell/.pi/agent/npm/node_modules/billion-context` — version `0.1.188`, declared as `npm:billion-context` in `~/.pi/agent/settings.json` `packages`. The pi plugin (`dist/agent/pi-native.js`, declared in `package.json` → `pi.extensions`) spawns the proxy from **this** copy. |
| Standalone global npm install | `/home/cjdell/.local/lib/node_modules/billion-context` — version `0.1.176`; provides the `bili` / `bili-proxy` symlinks in `~/.local/bin`. Used for the CLI (`bili doctor`, `bili export`, …); **not** what the live proxy runs. `bili doctor` calls this lane "host-managed (owned by pi)" because pi materialises the npm copy. |
| Config | `~/.config/billion-context/billion-context.json` |
| Config reference (not shipped with npm) | `https://raw.githubusercontent.com/ranxianglei/billion-context/master/CONFIGURATION.md` |
| Log | `~/.local/state/billion-context/bili.log` (rotates at 10 MB → `bili.log.old`) |
| Runtime state | `~/.local/state/billion-context/`: `proxy-origin` (origin, `instanceId`, pid, host, **port**, `lane`, `launchToken`, `codeFingerprint`), `port-zone.json` (`{"lanes":{"pi":18789}}`), `instances/<instanceId>.json`, `plugin-conversations.json` (conversationId → lastSeen) |
| Session state | `~/.local/share/billion-context/sessions/openai/<host>_<hash>.json` — envelope `{version, savedAt, id, payload}`; `payload` = `{meta, stats, messages, messagesFolded, metadata, state, blockContents, createdAt}`, with the folds in `state.blocks` and the nudge bookkeeping in `state.nudge`. Currently named e.g. `192.168.49.50_47951711a3379b0d26ab513c.json` (named by upstream origin). |
| Web UI / session browser | `http://127.0.0.1:18789/__bili/#/` |

### Port allocation (why it is 18789, not 18787)

`ZONE_PORT_BASE = 18787` (override with `BILI_ZONE_PORT`). Each agent **lane**
(`pi`, `omp`, `claude`, `codex`, …) gets its own instance/port, and the lane's
chosen port is pinned in `port-zone.json` so the next launch prefers it
(`lanePreferredPort(lane) = readZonePort(lane) ?? ZONE_PORT_BASE`). The pi lane
currently sits on **18789**; nothing listens on 18787, so there is no conflict.
The proxy is a child of the agent process (`bili pi`-style launch) and its
watchdog is armed on that parent pid (`health` → `watchdog.parentPid`), so it
dies with the agent.

Run command (from the running process): `node /home/cjdell/.pi/agent/npm/node_modules/billion-context/dist/index.js
start --host 127.0.0.1 --port 18789`. Management endpoints are loopback-only:
`/__bili/config`, `/__bili/config/reload` (POST), `/__bili/health`,
`/__bili/logs`, `/__bili/overview`, `/__bili/sessions`, `/__bili/stats`,
`/__bili/status`, `/__bili/upstream`, `/__bili/upstream/test`,
`/__bili/cache-report`, `/__bili/conflicts/clear`, `/__bili/agent-providers`,
`/__bili/external-summary/credential`, `/__bili/resign`, and the plugin face
`/__bili/plugin/{register,status,manifest,tool,compact,fork,snapshot,session-name,runtime-info}`.
`/__bili/plugin/status` needs `?conversationId=<id>`; `__bili/watcher` is a route
string in the bundle but `GET` returns `{"error":{"type":"not_found"}}`.

**There is still no per-session detail REST endpoint** — `GET
/__bili/sessions/<id>` → `not_found`; `/__bili/sessions` lists sessions and the
session JSON on disk is the source of truth for the effective config/blocks.

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
| `nudgeGrowthTokens` | `50000` | soft-nudge growth step: a nudge fires every ~this many tokens of newly-compressible content. Flattens the engine's adaptive growth band to a fixed step (sets both `growthFloor` and `growthCap`). It is **not** the whole gate — see *The nudge gate* below. |
| `preserveRecentMessages` | ~`5` | recent messages always kept out of a fold. |
| `preserveRecentTokens` | ~`5000` | recent tokens always kept. |
| `minCompressRangeChars` (legacy `minCompressRange`) | kernel default | minimum fold range in **characters**, not tokens. |

Other fields: `tiers` (tier2Trigger 1000 / tier3Trigger 2000), `protectedTools`,
`protectedLatestTools`, `neverPreserveRecentTools` (built-in
`["decompress","search_context","read","bash"]`), `preserveRecentTools`,
`prompts` / `promptPack` (`default`, `lean`), `absorb`, `ccr`, `search`,
`imageCompression` (off by default), `rules` (off by default).

### The nudge gate as implemented in 0.1.188

Read out of `dist/index.js` (defaults in `nudge:{…}`):
`maxContextLimitPct .75`, `minContextLimitPct .45`, `frequency 5`,
`iterationThreshold 15`, `force "soft"`, `growthRatio .05`, `growthFloor 5e4`,
`growthCap 5e4`, `minGrowthFloor 2e4`, `minGrowthRatio .45`,
`emergencyThresholdPct .95`, `tier2GrowthMultiplier 1.5`.

```js
nudgeGrowthTokens = resolveAdaptiveGrowth(window, nudge)
                  = min(growthCap, max(growthFloor, round(window * growthRatio)))
// config.compress.nudgeGrowthTokens overrides both bounds:
//   growthFloor = growthCap = nudgeGrowthTokens   -> interval = 100000 here
effectiveThreshold = hasPendingNudge ? floor(nudgeGrowthTokens / 2) : nudgeGrowthTokens
growthFloor_gate   = max(minGrowthFloor, minGrowthRatio * nudgeGrowthTokens)  // 45000 here
growthReady        = firstSightMassReady || (tokenCount - growthReference) >= growthFloor_gate
tier2Threshold     = round(nudgeGrowthTokens * tier2GrowthMultiplier)         // 150000
```

So a soft nudge needs **both** `max(t1Eff, t2Pending, t3Pending) >=
effectiveThreshold` **and** growth since the last nudge ≥ 45 % of
`nudgeGrowthTokens` (min 20 000). That 45 % sub-gate is the `floor 45000` in the
log lines — it is derived from `nudgeGrowthTokens`, not an independent knob, so
raising `nudgeGrowthTokens` raises both:

```
nudge idle: usage=48% (109486/229376), growth=26174/45000 (ref=83312, interval=100000), pendingT1=44272
```

`maxContextLimit` (90 % here) still bypasses the growth gate entirely, and
`emergencyThresholdPercent` (95 %) is the hard truncation wall.

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

Applied with `curl -X POST http://127.0.0.1:18789/__bili/config/reload`
(returns `{"ok":true,...}`); verify with `GET /__bili/config`. The change takes
effect on the next request, not mid-session. **Still live and confirmed on
2026-10-08**: `GET /__bili/config` echoes exactly this block, and sessions show
`contextWindow: 229376` = 262144 − min(`maxTokens` 32768, 0.125 × 262144).

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

The port is the pi lane's — read it from
`~/.local/state/billion-context/port-zone.json` (`{"lanes":{"pi":18789}}`).

```sh
# the authoritative health check: every install lane, versions, staleness, live procs
bili doctor            # 2026-10-08: "1 ok, 0 stale, 0 frozen, 0 broken; 1 live, 0 zombie"
bili plugin list       # per-host plugin install status (its version column says "unknown"
                       # for the pi lane — trust `bili doctor` instead)

P=$(node -e 'console.log(require("/home/cjdell/.local/state/billion-context/port-zone.json").lanes.pi)')
curl -s "http://127.0.0.1:$P/__bili/health"    # ok:true, version, watchdog.parentPid = the agent pid
curl -s "http://127.0.0.1:$P/__bili/status"    # version == diskVersion, stale:false, conflicts, inFlight
curl -s "http://127.0.0.1:$P/__bili/config"    # the live, merged config (proves the reload landed)
curl -s "http://127.0.0.1:$P/__bili/upstream"  # connectionUrl the proxy actually forwards to
curl -s "http://127.0.0.1:$P/__bili/overview"  # sessions/requests/folds(hitPct)/tokensSaved
curl -s "http://127.0.0.1:$P/__bili/plugin/manifest"  # toolNames the plugin injects

# is the plugin wired to THIS session? (needs the conversation id)
curl -s "http://127.0.0.1:$P/__bili/plugin/status?conversationId=$SID"

# errors / quality warnings (log has control chars -> grep -a)
grep -ac "\[error\]" ~/.local/state/billion-context/bili.log
grep -aoE "\[warn: [a-z-]+\]" ~/.local/state/billion-context/bili.log | sort | uniq -c

# what triggered each fold (uses the ratio key + reason string)
grep -aE "nudge (INJECT|INJECT-ESC)" ~/.local/state/billion-context/bili.log | tail -20

# reload after editing the config
curl -s -X POST http://127.0.0.1:$P/__bili/config/reload
```

The pi-side chain for this box (2026-10-08): pi provider `strata` (`baseUrl
http://192.168.49.50/v1` in `~/.pi/agent/models.json`) — the plugin repoints that
at the proxy, so the request lands on `127.0.0.1:18789`, and the proxy forwards
it to `http://192.168.49.50/v1/chat/completions` (nginx :80 → Strata
`127.0.0.1:8080`, `strataRootLocation` in `hosts/zen3-nixos/ai/strata.nix`).
`health`'s `"upstream":"https://api.anthropic.com"` is just the unresolved
default target; `/__bili/upstream` shows the real `connectionUrl`.

### `[warn: degenerate-fold]` — the one warning worth watching

Not a failure, but it costs the prompt cache: the fold covered nearly the whole
live context, so the stable prefix is rewritten and the cache restarts from
scratch. Observed 5× in the current log window, once on 2026-10-08:

```
[warn: degenerate-fold] [acp-compress-obs] covers 90% of the live context
(~56077/62209 tok) leaving 4 active block(s), anchor≈2700 tok — the whole prefix
rewrites and the prefix cache restarts from scratch
```

and the next request confirmed it: `[acp-usage] input=35852 cached=16384 (cache
hit 46%)` against the usual 92–98 %. It happens when the agent compresses almost
everything in one call; the fix is behavioural — fold smaller ranges and leave
the oldest blocks in place (the `acp_cache` ledger shows the per-fold cost).

Updates: `autoRestartOnUpdate: false`, so an npm bump does **not** restart the
running proxy — `status`/`bili doctor` will report `stale: true` until it is
restarted. The pi lane is owned by pi (`pi update --extension
npm:billion-context`); the proxy self-drives a refresh each check cycle (#1196).

Note: this `billion-context` proxy is a **separate thing from pi's own
auto-compaction**. The folds/`📦 [ACP]` markers in an agent session come from
this proxy, and tuning it here is what changes their frequency.
