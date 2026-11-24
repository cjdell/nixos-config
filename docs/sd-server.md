> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## stable-diffusion-cpp (Flux-schnell service + SDXL on disk)

`stable-diffusion-cpp` is installed on zen3-nixos as a **Vulkan build** — the
nixpkgs default is CPU-only (`SD_VULKAN=OFF`), so `hosts/zen3-nixos/ai/sd-server.nix`
uses `(stable-diffusion-cpp.override { vulkanSupport = true; })`. The binaries
are `sd-cli` and `sd-server` (upstream renamed from `sd`). **Since 2026-11-06
the service runs FLUX.1-schnell; SDXL remains on disk for ad-hoc `sd-cli` use.**

- Models live in `/home/cjdell/sd-models`: the Flux set (see the sd-server
  section) plus SDXL base fp16 (`sd_xl_base_1.0.safetensors`, 6.5G) +
  `clip_l.fp16.safetensors`, `clip_g.fp16.safetensors`,
  `sdxl_vae.fp16.safetensors` (from `stabilityai/stable-diffusion-xl-base-1.0`).
- Vulkan device numbering: sd-server.nix pins sd-server to the R9700 with the
  same device-select layer env (`MESA_VK_DEVICE_SELECT=1002:7551!`), so
  `vulkan0` = R9700 and the console GPU is not visible to it. Same for all
  three llama-swap routers (see the gotchas section).

Working test command (1024×1024 SDXL, ~24 s for 30 steps on the R9700):

```sh
sd-cli --backend "diffusion=vulkan0,clip=vulkan0,vae=vulkan0" \
  -m /home/cjdell/sd-models/sd_xl_base_1.0.safetensors \
  --vae /home/cjdell/sd-models/sdxl_vae.fp16.safetensors \
  --clip_l /home/cjdell/sd-models/clip_l.fp16.safetensors \
  --clip_g /home/cjdell/sd-models/clip_g.fp16.safetensors \
  -p "a majestic golden retriever in a sunlit meadow" \
  -H 1024 -W 1024 --steps 30 --cfg-scale 6 --vae-tiling \
  -o out.png
```

**Gotcha — `--vae-tiling` is required for VAE decode.** RADV reports
`maxMemoryAllocationSize = 0xfffffffc` (~4 GiB) on the R9700, and the SDXL
VAE decode graph wants an ~8.5 GB buffer; ggml's single allocation (4.5 GiB)
then fails with `ErrorOutOfDeviceMemory` even though 32 GB VRAM is free.
`--max-vram` (graph-cut) does **not** fix it — only `--vae-tiling` (or putting
the VAE on CPU: `--vae-on-cpu`). Bigger graphs (Flux/SD3 at high res) will hit
the same cap.

### sd-server: Flux-schnell on stable-diffusion.cpp (started by `gpu-mode sd`)

**`sd-gate` was retired 2026-11-06 and SDXL replaced by FLUX.1-schnell**
(Apache, 4-step guidance-distilled, much better per watt). With `gpu-mode`
as this box's scheduler the gate's spawn-on-connection + 120 s idle-kill
automated something the lease now does by hand — and for an ~18 GB GGUF
set that reload-ping-pong would have been actively bad. What remains is a
plain unit, **`sd-server`** (`hosts/zen3-nixos/ai/sd-server.nix`): `sd-server`
on `127.0.0.1:8085`, **no `wantedBy`** — `gpu-mode sd` starts it and waits
until `GET /v1/models` answers (the model load is minutes on a cold page
cache), `gpu-mode llm|game` stops it. nginx `/sd-api` now proxies straight
to 8085 (was 8084 via the gate); **same URLs**, except the gate's
`/sd-status/` page is gone with it.

- **Weights** in `/home/cjdell/sd-models`, fetched by
  `scripts/fetch-flux-schnell.sh` (resumable, size+sha256 pinned):
  `flux1-schnell-Q8_0.gguf` (12.7 GB, city96/FLUX.1-schnell-gguf) +
  `t5xxl_fp8_e4m3fn_scaled.safetensors` + `clip_l.safetensors`
  (comfyanonymous/flux_text_encoders) + `ae.safetensors` (flux AE;
  camenduru/FLUX.1-dev mirror — BFL's own repo 401s unauthenticated).
  `ConditionPathExists` refuses to start the unit on an unprepared set.
- **The schnell recipe is baked into the unit**: `--guidance 1.0` (the
  3.5 default is FLUX-dev's distilled-guidance value), `--cfg-scale 1.0`
  (schnell needs no CFG branch), `--vae-tiling` (the flux AE decode hits
  the same RADV ~4 GiB allocation cap the SDXL VAE did), `--max-vram -1`,
  pinned by `MESA_VK_DEVICE_SELECT=1002:7551!` so `vulkan0` is the R9700.
  VRAM: ~12 GB DiT + ~5 GB t5 + graphs — comfortable with the LLM off lease.
- **Web UI:** `http://192.168.49.50/sd/` or `https://sd.ai.chrisdell.info/`
  (`sd-webui/`, copied into the store via `runCommandLocal`). Defaults are
  now the schnell recipe (steps 4 / cfg 1 / euler), the status pill says
  *server down — gpu-mode sd* when the unit is off (no more auto-wake), and
  the localStorage key moved to `-v2` so stale SDXL-era slider memory does
  not resurrect itself.
- **API:** `POST http://192.168.49.50/sd-api/sdapi/v1/txt2img` (full param
  control: steps/cfg/seed/sampler/negative_prompt), or
  `https://sd.ai.chrisdell.info/{sd-api,sdapi,v1}/…`; the OpenAI-style
  `/v1/images/generations` on this build still **ignores** steps/cfg/seed.
- **Strata's `before_load` hook stops `sd-server`** (`hosts/zen3-nixos/ai/strata.nix`)
  — the one lease-protection direction that survived the gate: an engine
  reload cannot land on a full card. The reverse (the gate's old
  `POST /v1/unload` eviction + auto-reload dance) is gone; the lease is
  unit state and `gpu-mode` is the only switch.
- **SDXL is still on disk** (8.2 GB total) for `sd-cli` experiments with the
  test command above; pointing the unit's model args back at it is a
  second-service change if it is ever wanted as a service again.

## GPU modes: `gpu-mode llm | sd | game` (zen3-nixos)

(The `llm` lease commands `strata.service` again since 2026-11-04, after the
same-day Avalon interlude — "ready" comes from Strata's `/v1/status`
`loaded:true`, and sd/game evict via `POST /v1/unload` + stopping
`strata.service`; if you ever flip back to Avalon, revert `gpu-mode.sh` from
git history too — it is engine-specific. See the Avalon section for that
lease's `/health` + `/slots` form.)

One 32 GiB card, three jobs that each want it whole: the Strata LLM, Stable
Diffusion, and (occasionally) a game. `gpu-mode`
(`hosts/zen3-nixos/ai/gpu-mode.nix` + `./gpu-mode.sh`, installed on PATH)
makes the card a **lease**:

- `gpu-mode` — status: which mode holds the card, per-unit state, whether
  Strata's model is loaded / flux is ready, what is in flight, MiB free.
- `gpu-mode llm` — stop `sd-server`, start `strata`, wait until `/v1/status`
  reports `loaded:true` (the model load is **multi-minute**, ~60 GiB RAM;
  the box is sluggish while it fills). **The boot default.** If the serve
  layer is already up but its engine was evicted, it sends a 1-token warm-up
  request so "ready" really means ready.
- `gpu-mode sd` — stop `strata`, wait for the VRAM, then start `sd-server`
  and wait until flux answers `GET /v1/models` (~18 GB; minutes on a cold
  page cache). It stays loaded for the whole lease — no idle-unload since
  sd-gate was retired 2026-11-06.
- `gpu-mode game` (aliases `free` / `off`) — stop both: 32 GiB of VRAM and
  the ~60 GiB of RAM Strata held come back. Polls `amd-smi` until free.

The lease is exclusive by *unit state*: sd/game **stop** `strata.service`
(not merely unload it), so background Pi/Recallium traffic cannot
auto-reload the 90 GB model into VRAM mid-game — the LLM endpoints answer
502 while off lease, which is the point. Interactive switches warn + confirm
if a Strata turn is in flight. A reboot always restores `llm`
(`sd-server.service` deliberately has no `wantedBy` — only `gpu-mode` starts
it). The one overlap that could still arise — `strata.service` started by
hand during an sd lease — is guarded by Strata's `before_load` hook, which
stops `sd-server` before the engine reloads. The script calls
`/run/wrappers/bin/sudo` (passwordless wheel on this host), so no polkit
rule is needed.

