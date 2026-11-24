> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## LFM3-1.7B on the RX 580 (`lfm3.service` — the second-card lane)

`hosts/zen3-nixos/ai/lfm3.nix`: stock llama.cpp **Vulkan** (`llamaCppPkgs.vulkan`,
the flake's `llama-cpp` input — `a0677c34` (2026-11-23 HEAD, moved from
`956591f4` 2026-11-11 for Inkling-2-Mini's #32704 floor, see the Inkling
section; must stay ≥ upstream b11960 for lfm3) serving
`LFM3-1.7B-Q4_K_M.gguf` (from `scripts/fetch-lfm3-1.7b.sh`, rev+size+sha256 pinned)
on the **RX 580 = the console GPU** (`1002:67df`, renderD128). Loopback
`127.0.0.1:8086`; `lfm3.ai.chrisdell.info` (UI + API) and `/lfm3/` on the IP vhost.

- **Not part of the `gpu-mode` lease and cannot disturb Strata:** the unit pins
  `MESA_VK_DEVICE_SELECT=1002:67df!`, so the R9700 is *invisible* to it —
  verified: the process holds only renderD128, and `gpu-mode` still manages
  only strata + sd-server. Always on (`wantedBy`); a `nixos-rebuild switch`
  that touches nothing else does not restart `strata.service`.
- **The RX 580 is a 4 GiB card** (not 8 — llama.cpp reports 4096 MiB, ~3.6 GiB
  free under Plasma). `--ctx-size 131072` (raised from 32768 the same day):
  cost model from two measured points = ~1126 MiB fixed (weights+graphs, LFM3
  keeps KV on 11 of 24 layers) + ~12.99 KiB/token → 131072 sits at ~2.8 GiB,
  ~800 MiB slack. Hard ceiling ~185-190K — don't chase it (that slack is the
  GTT-spill insurance for the console GPU) and the full 262144 native window
  cannot fit. With `kv_unified` the pool commits once and the 4 llama-server
  slots share it — n_slots doesn't multiply KV memory. Real limit is prefill:
  ~90-220 tok/s, so a cold 131K prompt is a 10-25 min first token.
- Measured on Polaris (no coopmat): **76.9 tok/s decode, 87–223 tok/s
  prefill**, `n_slots 4` (llama-server default parallelism — unlike Strata's
  one-slot engine, concurrent small requests are fine here). ⚠️ LFM3 is a
  reasoning hybrid: it fills `reasoning_content` BEFORE `content`, so a small
  `max_tokens` yields a correct-looking `finish_reason: length` with EMPTY
  `content` (budget 240+ for one-line answers). gfx803 has no
  ROCm/HIP path; Vulkan/RADV it is (`WARNING: radv is not a conformant
  Vulkan implementation` in the log is normal).
- **Server-side tools are ON** (`--tools all`, since 2026-11-11): llama.cpp's
  built-ins (`read_file, file_glob_search, grep_search, exec_shell_command,
  write_file, edit_file, get_info`) run in llama.cpp's own sandbox —
  `--tools-runtime podman:docker.io/library/python:3.11-slim` keeps a
  `podman run --rm -i … sh` alive for the server's lifetime and routes every
  call through `podman exec`; verified the model cannot see `/home/cjdell`
  from inside. **Never drop the runtime flag on a reachable endpoint** —
  without it the tools execute as the service user (root). The unit needs
  `path = [ pkgs.podman ]` (NixOS gives units a minimal PATH and llama.cpp
  execs podman from it — missing podman = crash-loop `failed to spawn podman
  container`). Chat contract: `GET /tools` for schemas → chat returns
  `tool_calls` → caller executes via `POST /tools {"tool":…,"params":…}` →
  send result back; the Web UI does this loop itself. Because tools + public
  endpoint = an agent runtime for the anonymous internet, the
  `lfm3.ai.chrisdell.info` vhost is allow-listed to LAN/VLAN10/WG/tailnet +
  the LAN /64 + leighhack's `2001:8b0:1d14::/48` (`deny all`, hass-rs
  pattern); the IP vhost `/lfm3/` needs no list (RFC1918 = LAN-only). ⚠️ The
  llama.cpp Web UI shows a misleading "API key required" for ANY non-2xx
  `/props` response — if a legit client hits the deny rule, check
  `journalctl -u nginx | grep 'access forbidden'` before blaming auth
  (2026-11-11: user browsing from leighhack hit exactly this).
- **MCP: not wired.** llama.cpp's MCP client (#26062, `--mcp-servers-config`,
  Cursor JSON) is **stdio-only** — MCP servers spawn as child processes with
  the server's (root) privileges. Recallium/diamcp speak Streamable HTTP, so
  nothing connects without a stdio↔HTTP bridge; `--ui-mcp-proxy` is unrelated
  (it lets the *browser* UI reach remote MCPs).
- ⚠️ `nix flake update llama-cpp` does **not** rebuild Strata: strata-package.nix
  `fetchFromGitHub`s its own pinned llama.cpp `3cf03257` for `tools/vision`
  only, independent of this input. Bumping `llama-cpp` only moves llama-swap's
  (disabled) build, alderlake's, asus' and this service's next switch.

