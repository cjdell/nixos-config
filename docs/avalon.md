> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## Avalon (Qwen3.8-Flash-Next on the R9700 — DISABLED 2026-11-04, same day)

⚠️ **Rolled back to Strata on 2026-11-04.** Avalon ran on `:8080` for part of
that day; the flip-back is the import swap in `hosts/zen3-nixos/ai/default.nix`
(comment `./avalon.nix`, uncomment `./strata.nix`) **plus** restoring
`gpu-mode.sh` + `sd-server.nix` (formerly `sd-gate.nix`) to the matching era's version from git history —
the lease logic is engine-specific. Everything below stays as the deployment
record (it worked: 2,115 t/s prefill, 89 t/s decode, vision via mtmd) and the
rollback procedure.

**Avalon** (github.com/freriadoc/Avalon) replaced Strata on `127.0.0.1:8080`
on 2026-11-04 — deliberately, keeping **every client URL identical**: it is a
fork of llama.cpp tuned for exactly the one model this box serves
(Qwen3.8-Flash-Next, 512-expert MoE), with the experts hosted in system RAM,
a GPU expert cache prefilled from `moe-cache-ranking.bin`, MTP speculative
decoding from a shared draft head, and fused RDNA kernels. Same idea as
Strata, llama.cpp-native serve surface: no Python serve layer, no
hang-watchdog core dumps (docs/strata-hang.md), no ROCm-10 runtime override,
no #879 audit patch to re-base every release. Upstream numbers: 86.6 t/s on
an R9700 (user-reported) where their Strata showed 31 — our Strata measured
60-64 tok/s on the UD-IQ4_XS pack on 0.2.7.1, so Avalon's realistic win here
is prefill (~1,500-1,900 t/s vs our ~1,250) and long context. RDNA4 is
"reported working, not measured" upstream — treat the first days accordingly.

- **Flake:** input `avalon = github:freriadoc/Avalon` (nixpkgs follows ours).
  Its `.devops/nix/` tree is unmodified llama.cpp, so `nix build .#avalon` =
  `hosts/zen3-nixos/ai/avalon-package.nix` instantiating that scope with
  `useRocm = true`, `rocmGpuTargets = "gfx1201"` (nixpkgs ROCm 7.2.3 — clr
  lists gfx1201 and rocblas/hipblas build Tensile kernels for it; upstream
  tests on 7.2.4) and `LLAMA_BUILD_TESTS=OFF` (the llamaCppPkgs ICE reason).
- **Service `avalon.service`** (`hosts/zen3-nixos/ai/avalon.nix`): stock
  `llama-server` on `127.0.0.1:8080`, OpenAI-compatible; the run line is
  Avalon's documented `avalon-server` command (262144 ctx — Strata's
  393216-via-YaRN is NOT repeated, `-b/-ub 9536`, FA on, KV q8_0/q4_0,
  `--parallel 1`, MTP 2 drafts, `--fit` default) plus `--alias
  qwen3.8-flash-next`, `--slots` (gpu-mode's in-flight check),
  `--cache-reuse 256`, `-cram 16384` (**MiB** - 16 GiB cap on the RAM prompt
  cache, llama.cpp's units; the llama-swap-era `-cram 65536` = 64 GiB OOM'd
  this box) and `--log-prompts-dir llama-logs/`, which
  revives llama-log-viewer (dark since llama-swap stopped writing it).
- **Model data** lives OUT of the store:
  `/home/cjdell/Models/Qwen3.8-Flash-Next-Avalon-GGUF` (33 IQ3_KS-hybrid
  shards, `MTP/mtp-…FR65k.gguf`, `moe-cache-ranking.bin`, ~89.7 GiB) from
  `scripts/fetch-avalon-model.sh` (HF rev `372fe3a4e572c5ba75a90e579de0695633d083a8`
  pinned, per-file size + sha256, resumable; `--check` verifies). The unit's
  `ConditionPathExists` refuses to start an unprepared set. The IQ3_KS
  hybrid keeps ISTA's experts and re-quantises 27 layers' gate/up from the
  BF16 original with an imatrix: better perplexity than the IQ3_S Strata
  served, close to UD-IQ4_XS, at 89 instead of 93.7 GiB.
- **URLs are unchanged on purpose:** the `/` location on the `192.168.49.50`
  vhost, the `strata.ai.chrisdell.info` vhost (kept as the public name —
  same cert), `llm.`/`llama.ai` via `../tls.nix`'s wildcard fallback, and
  Recallium's `/recallium-llm/` all still proxy `127.0.0.1:8080`. llama.cpp's
  server ignores the requested `model` name (no 404 path), so Recallium's
  stale DB row and every client config keep working. `POST /v1/unload` and
  `/v1/status` are GONE (Strata-only endpoints): sd-gate's
  `--llm-unload-url` was dropped and `gpu-mode` now checks `/health`
  (200 = model resident) + `/slots`.
- **Lease differences vs the Strata era:** llama.cpp has no unload endpoint,
  so `gpu-mode sd|game` stopping `avalon.service` IS the eviction (an ad-hoc
  overlap runs SD at GTT-spill speed), and there is no auto-reload — after
  `gpu-mode llm` the unit loads the model before `/health` goes 200. Also
  parked for now:
  **multi-conversation KV parking** (a Strata feature; llama.cpp re-reads a
  switched-away prompt, softened by `--cache-reuse`/`-cram`), and
  >262144-ctx YaRN extrapolation. **Vision is ON since 2026-11-04:**
  `--mmproj /home/cjdell/Models/mmproj-Qwen3.8-Flash-Next-BF16.gguf
  --no-mmproj-offload` (the same ISTA `qwen3vl_merger` encoder Strata's
  strata-vision used; Avalon's fork carries `tools/mtmd/models/qwen3vl.cpp`,
  verified by a CPU-only `llama-mtmd-cli` load + red-PNG answer before
  enabling). The ~1 GiB encoder stays on CPU — the expert cache leaves ~100
  MiB of VRAM — encoding ~5 s/image. Deleting that file without removing the
  flag kills the service at load.
- **Rollback:** swap the `./avalon.nix` / `./strata.nix` imports in
  `hosts/zen3-nixos/ai/default.nix` — Strata's packs, config and
  `rocm10-runtime.nix` are untouched; importing both would double-bind
  :8080, so never enable them at once.

