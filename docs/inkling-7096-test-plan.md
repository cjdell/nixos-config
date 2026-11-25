# Test plan: Niko1221/Strata#7096 — the three runs the maintainer asked for

**Status:** **run 2026-11-25 11:26–12:19 GMT**, results posted as
<https://github.com/Niko1221/Strata/issues/7096#issuecomment-7162254328>. Headline:
the three requested runs all completed (stock serve/default chunk, build's 7.2.x
libraries, and a ~4K replacement at chunk 2048); `--chunk 2048` did **not**
reproduce the wedge in five synthetic replacement runs; and the "first chunk took
190 s" claim was wrong — that number is queue wait, see § R0/retraction below.
Written 2026-11-25 ~11:15 GMT, after the maintainer's reply
(2026-11-25T10:03Z) to <https://github.com/Niko1221/Strata/issues/7096>.
Run this in a maintenance window when nothing needs the R9700 — it owns the card
exclusively, and this box's main lane (`strata.service`, `gpu-mode llm`) must be
stopped for the duration (also stop `strata-swap.service`, or the :8080 shim can
start a swap lane into the middle of a run). Budget **~1 h** (4 engine starts +
cold reads).

Read first: `docs/inkling-depth-wedge-2026-11-24.md` (the wedge itself) and the
issue thread. The maintainer's asks, verbatim:

1. Same 82K prompt at the **default chunk** (no `--chunk`) with the **stock serve layer**.
2. Same prompt with the **ROCm libraries the build was made for** (nixpkgs 7.2.x),
   not the 10.0.0 runtime prepended via `lib_dirs`.
3. A **~4K prompt at `--chunk 2048`** while a large context is resident — does the
   first chunk take minutes on its own?

Plus, for every run: engine stderr start→wedge (`[ink-hip]` lines), the output of
`STRATA_INK_PROF=1`, and raw `PP` lines (see § why). They also offered to take the
collapse dumps; scrubbed set kept at `/var/lib/inkling/collapse-scrubbed-20261125.tar.gz`
(168 KB, 20 files, no model text / no IPs — re-verify before publishing anything).

## What we owe beyond the three runs (draft-comment facts already in hand)

- **The 79K-in-10 s progress cannot be our patched serve layer.** The
  `[strata] reading the prompt: X of Y tokens, T s so far` line is printed by
  STOCK code (`share/strata/serve/server.py:5835` at 0.2.21); `X` is
  `self.engine.progress[0]`, set verbatim from the engine's `PP` lines at
  `server.py:1565` and `:2725` — comment at `:788`: "(read, total) prompt tokens
  while a prompt is read, **from PP lines**". None of our five diffs touch the
  parser or the print. BUT: we never recorded the raw `PP` lines — serve consumes
  them, and `/var/lib/inkling/inkling.log` only keeps the narrated lines
  (`grep -c PP` → 0). The re-runs must echo them: `PP <pos> <total> <ms since
  prompt start> <mean tok/s>` — fields 3–4 are the engine's own timers and will
  show whether the engine *believed* it read at 7,900 t/s.
- **`--chunk 2048` provenance**: ours, knowingly (the config comment has always
  said the default is 512; we chose 2048 for measured prefill speed: 1,348 vs
  874 t/s at 8K, 1,219 vs 738 at 32K). Concede, then make the real claim: a valid
  flag value must not wedge forever silently — init should refuse/clamp, and the
  no-progress watchdog (#29, Flash-Next serve) doesn't cover this path.
- **Soak since filing**: 512 (explicit) served ~52 min of real agent traffic
  after the first 82K replace read (turns 28–83K, 38–43 t/s decode, `done:` every
  turn, zero wedges, zero new collapse dumps), then `gpu-mode llm` took the card
  back at 00:44 cleanly. Quote it — it upgrades "one observation" to ~1 h.

## The matrix

`R0` is run first: if the harness cannot wedge at 2048 tonight, STOP and report
the non-reproduction (that is itself an answer for the issue). Every run = fresh
engine start → **A** prompt ~83K salt `A7096` completes (this makes the resident
context) → **B** prompt arrives with prefix match 0 (forces the replace path) →
observe.

| run | chunk | serve layer | engine libs | B prompt | question it answers |
| --- | --- | --- | --- | --- | --- |
| R0 | 2048 | patched (unit's) | rocm10 prepend | 82K `B7096` | harness sanity: does it still wedge? |
| T3 | 2048 | patched | rocm10 prepend | **4K** `C7096` | is the 190 s chunk-1 stall about *replacing* or about the *new prompt's size*? |
| T2 | 2048 | patched | **none** (build's 7.2.x) | 82K `B7096` | is our ROCm-10 prepend the hidden variable? |
| T1 | *absent* (default) | **stock** | rocm10 prepend | 82K `B7096` | their ask 1; doubles as the "your patches didn't do it" control |

Order: R0 → T3 → T2 → T1. Every run is a **fresh engine start** (a wedged engine
is unrecoverable, and serve holds it), so ~4 starts ≈ 1 h total.

## Prep (once)

```sh
D=/tmp/opencode/7096; mkdir -p $D && cd $D
# unit's config + paths, resolved live (never hardcode store paths — they change on rebuild):
CFG=$(systemctl show inkling-2-mini -p ExecStart | grep -o '/nix/store/[^ ]*strata-inkling\.json')
SERVE=$(systemctl show inkling-2-mini -p ExecStart | grep -oP '/nix/store/[^ ]*strata-inkling-serve')
PY=$(grep -oP '/nix/store/[^"]*python3[^"]*-env/bin/python3' "$SERVE/bin/strata-server")
STOCK=$(ls -d /nix/store/*-strata-inkling-0.2.21/share/strata | head -1)   # stock serve layer

# TWO writable serve trees, BOTH with the raw-PP echo (so "patched" rows keep our 5
# patches and only the serve-layer variable differs between runs):
cp -r "$STOCK" share-stock-pp && cp -r "$SERVE/share/strata" share-patched-pp && chmod -R u+w share-*
python3 - <<EOF
import re
pat = r"^(\s*)self\.progress = \(int\(f\[1\]\), int\(f\[2\]\)\)(.*)$"
rep = r"\1print(\"[pp-raw]\", line, flush=True)\n\1self.progress = (int(f[1]), int(f[2]))\2"
for p in ("share-stock-pp/serve/server.py", "share-patched-pp/serve/server.py"):
    s = open(p).read()
    s, n = re.subn(pat, rep, s, flags=re.M)
    open(p, "w").write(s); print(p, "PP echo inserted at", n, "sites (want 2)")
EOF
```

Per-run config (same JSON, three knobs: `args` chunk, `lib_dirs`, `log`; PROF env
for all runs):

```sh
cfg() {  # cfg <tag> <chunk:2048|512|none> <libs:rocm10|build>   -> writes $D/cfg-<tag>.json
  sudo -n python3 - "$CFG" "$D/cfg-$1.json" "$2" "$3" "$1" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
a = d["args"]
if sys.argv[3] == "none":
    a = a[:a.index("--chunk")] + a[a.index("--chunk") + 2:]     # drop the flag -> engine default (512)
else:
    a[a.index("--chunk") + 1] = sys.argv[3]
d["args"] = a
d["lib_dirs"] = [] if sys.argv[4] == "build" else d["lib_dirs"]  # T2: RUNPATH'd nixpkgs 7.2.x only
d.pop("before_load", None)                                       # don't let a test serve touch sd-server
d["log"] = f"/tmp/opencode/7096/engine-{sys.argv[5]}.log"
d["env"] = dict(d["env"], STRATA_INK_PROF="1")
json.dump(d, open(sys.argv[2], "w"), indent=1)
print("cfg-" + sys.argv[5] + ":", " ".join(d["args"][d["args"].index("--chunk"):d["args"].index("--chunk")+2]) if "--chunk" in d["args"] else "(default chunk)", "| lib_dirs:", d["lib_dirs"])
EOF
}
# cfg R0 2048 rocm10 ; cfg T3 2048 rocm10 ; cfg T2 2048 build ; cfg T1 none rocm10
```

Start/stop for one run (manual serve — deliberately NOT the unit, so a rebuild
can't touch the test bed and every artifact lands in `$D`). `SHARE` switches the
serve layer per run; `RUN` the tag:

```sh
RUN=R0; SHARE=$D/share-patched-pp; cfg R0 2048 rocm10        # T1: SHARE=$D/share-stock-pp
sudo systemctl stop strata inkling-2-mini
sleep 3; pgrep -f '[b]in/strata-inkling --serve' && sudo pkill -f '[b]in/strata-inkling --serve'   # orphans eat VRAM
cd $D
PYTHONPATH=$SHARE STRATA_DEBUG=1 nohup "$PY" -m serve.server \
  --engine strata --config $D/cfg-$RUN.json --host 127.0.0.1 --port 8094 > serve-$RUN.log 2>&1 &
until timeout 3 curl -s http://127.0.0.1:8094/v1/status | grep -qE '"loaded": ?true'; do sleep 5; done   # ~90-150 s cold
grep "SWA KV ring" engine-$RUN.log                            # confirm the ring before exercising
```

Exercise (patched serve exposes `/metrics`; **stock serve does not** — there,
watch the `reading the prompt:` lines in `serve-RX.log` instead):

```sh
# (no python3 on PATH on this box: prefix with `nix shell nixpkgs#python3 --command` if your shell lacks it)
python3 ~/nixos-config/scripts/inkling-depth-check.py 83000 --salt A7096 --max-tokens 8   # completes -> context resident
python3 ~/nixos-config/scripts/inkling-depth-check.py 82000 --salt B7096                  # THE replace; watch
# T3 replaces the second line with:  ... 4000 --salt C7096
```

Capture on stall (no first token after 300 s, or `read` advancing past `prompt` in
a way that implies skipping):

```sh
B=$D/cap-R0-$(date +%H%M%S); mkdir -p $B
P=$(pgrep -f '[p]ython3 -m serve.server'); E=$(pgrep -f '[b]in/strata-inkling --serve')
timeout 5 curl -s http://127.0.0.1:8094/metrics > $B/metrics.json || true
timeout 5 curl -s http://127.0.0.1:8094/v1/status > $B/status.json || true
ps -T -p $E -o tid,stat,wchan:24 > $B/engine-threads.txt 2>/dev/null
timeout 6 amd-smi metric --json > $B/amd-smi.json 2>&1
cat /sys/class/drm/card*/device/mem_info_{vram_used,gtt_used} > $B/gpu-mem.txt 2>/dev/null
sudo -n py-spy dump --pid $P --locals > $B/pyspy.txt 2>&1   # nix shell nixpkgs#py-spy --command ...
kill -INT $P; sleep 30; kill -KILL $P $E 2>/dev/null        # then verify orphan-free + VRAM freed before the next run
```

## Fill this in as you go

| run | chunk | serve | libs | B result | prefill ms (B) | first token? | chunk-1 time | PP lines say | verdict row for the comment |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| R0 | 2048 | patched | rocm10 | **no wedge** ×5 | 91,170–100,543 | yes | ~1.5 s | `PP 81064 81064 91129.9 889.5` (total = prompt) | non-reproduction (five variants) |
| T3 | 2048 | patched | rocm10 | completed | 3,112 (B = 3,963 tok) | yes, 28 tok | ~1.5 s | `PP 3963 3963 3094.0 1280.9` | no minute-long chunk-1 |
| T2 | 2048 | patched | **7.2.x** | completed | 92,782 | yes, 28 tok | ~1.5 s | `PP 81064 81064 92742.2 874.1` | libs not the variable |
| T1 | default (512) | **stock** | rocm10 | completed | 135,298 | yes, 28 tok | n/a (512) | `PP 81064 81064 135258.3 599.3` | stock serve/default chunk clean |

## Results (2026-11-25, as run)

Engine 0.2.21 / strata-inkling 0.1.67, SQ-20, `--max-context 163840 --kv fp8
--vision … --dspark … --draft off`, one slot, GPU idle, fresh engine per run,
manual `serve.server` on :8094 with `STRATA_DEBUG=1`, `STRATA_INK_PROF=1`,
`STRATA_INK_PARK=1`. Serve trees: `share-stock-pp` (stock 0.2.21 tree + a 2-line
raw-PP echo) and `share-patched-pp` (our five diffs + the same echo). Artifacts:
`/tmp/opencode/7096/` (`serve-RX.log` with `[pp-raw]` lines, `engine-RX.log`
with `[ink-hip]` lines, `probe-RX-A/B.out`, `cap-RX-*`).

| run | A (resident) | B | A read | B read | B out | verdict |
| --- | --- | --- | --- | --- | --- | --- |
| T1 stock serve, no `--chunk` (ring 1536 / span 512) | 82,087 | 81,064 | 137.8 s | 135.3 s (599 tok/s) | 28 tok, needle ok | completed |
| T2 build RUNPATH 7.2.x (0 `rocm10` in maps) | 82,087 | 81,064 | 94.6 s | 92.8 s (874 tok/s) | 28 tok, needle ok | completed |
| T3 `--chunk 2048`, B ≈ 4K | 82,087 | 3,963 | 92.9 s | **3.11 s** (1,281 tok/s) | 28 tok, needle ok | completed |

R0 (chunk 2048) replacement runs, each completed with `PP total == prompt len`:
A 82,087→B 81,064 (91.2 s); A 85,090→B 81,064; A 78,061→B 81,064 (B longer than
A); A 85,090→B 87,070 (over the context); A 81,071 + 2,500 generated (slot held
83,570) →B 87,070 queued behind the generating turn. So chunk 2048 is
necessary-but-not-sufficient in a synthetic harness; the real resident context
was grown turn-by-turn with prefix reuse/checkpoints, which a fresh engine lacks.

### Retraction: the 190 s "chunk-1 stall" was queue wait

`_progress()` (stock 0.2.21 `server.py:5875-5886`) prints `el = now - started`,
and `started` is `began` (`:2055`, `:2261`) — set when the request enters the
batch path, **before** it is admitted while another turn is generating. A request
queued behind a 2,500-token generation printed `93 s so far` one second after
admission (its real read: `PP 81246 81246 39.6 25.2`). What remains unexplained
is the *total* on that line: in the original capture the prompt was 81,865 tokens
but progress went `(2,048, 81,042)` → `(81,042, 81,042)`, i.e. 823 short — the
progress total comes from the engine's own `PP` (`:1565`, `:2771`), which none of
our diffs touch. Two readings, both open: the engine clamped `n_past`, or another
pass wrote the shared `engine.progress` (seen live: a queued request's view
showing the wrap-up pass's 81,246/81,246).

### Reading the numbers

- `PP <pos> <total> <ms since prompt start> <mean tok/s>` — mean, not a window,
  so it declines with depth (1,349 tok/s at 2K → 866 at 87K on chunk 2048).
- The engine emits a trailing `PP <n+6> <n+6> ~40 ms ~25 tok/s` after a response,
  and the request table's `prompt_ms` ends up holding that 40 ms — trust the PP
  lines, not `/metrics prompt_ms`.
- Two concurrent requests on the one-slot config (our own harness slip in the
  first T2 attempt) still collapse decode to 0.1–3.5 tok/s though they finish —
  the known two-active class, not part of these results.

Reading the outcome (each branch is still worth posting):

- **R0 wedges, T2 does not** → our ROCm-10 prepend is load-bearing for the bug.
  Say so loudly — it's also evidence for #6420's class, and we'd re-test the
  prepend's own rationale (the #879 audit was on Flash-Next, not Inkling).
- **R0 wedges, T3 also stalls its first chunk on a 4K prompt** → the stall is in
  *replacing* a large resident context, chunk size and new-prompt size secondary.
- **R0 wedges, T3's 4K read is normal-speed** → the stall needs a large *new*
  prompt too; narrows to the multi-chunk replace path.
- **R0 does NOT wedge** → non-reproduction, post that (with the exact harness),
  plus T1's confirmation that stock-serve/default-chunk is fine. Do not chase.

## The reply comment afterwards (one comment, after all runs)

Contains: the three results table; raw `PP` excerpts (before/at/after the skip);
`STRATA_INK_PROF` excerpt; the code-path facts from §"What we owe" (stock line
numbers quoted); the `--chunk 2048` concession + "valid flag must not wedge
silently / no watchdog coverage" ask; the ~1 h soak data; whether the scrubbed
dumps were re-attached (ask before re-gisting; they're at
`/var/lib/inkling/collapse-scrubbed-20261125.tar.gz`, scrub verified 2026-11-25);
and one question: confirm `PP <pos> <total> <ms> <mean-tok/s>` field order.

## Cleanup (non-negotiable — this is the production box)

```sh
sudo nixos-rebuild switch --flake ~/nixos-config   # lane config back to chunk 512, patched serve, rocm10
sudo systemctl stop strata                          # AGENTS.md: a switch starts strata regardless
sudo systemctl start inkling-2-mini                 # or: gpu-mode llm to hand the lease back
pgrep -f '[b]in/strata-inkling --serve' || echo "no orphans"
timeout 6 curl -s http://127.0.0.1:8094/v1/status | head -c 200
```

Zen3 has autoRollback commented out — no `nixos-confirm`. This opencode session
is served by `strata.service`: stopping it for the test window kills my model
lane, so run the tests when you're done delegating to me, not mid-task.
