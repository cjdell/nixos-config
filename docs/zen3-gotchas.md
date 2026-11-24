> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## Known gotchas on this host

- **`/nix/store` is bind-mounted read-only for everything except `nix-daemon`.**
  PID 1's `mountinfo` shows `/dev/nvme0n1p3 … /nix/store ro,nosuid,nodev` (the
  ext4 itself is `rw`) and the daemon carries its own `rw` bind, so builds work
  but `sudo rm -rf /nix/store/<path>` fails with *"Read-only file system"* — not
  a filesystem error, `dmesg` stays clean. Delete paths with **`nix store delete
  <path>`**, which goes through the daemon. Related: a `nix build` backgrounded
  from an agent shell dies when the tool call ends, the daemon cancels the build
  on client disconnect and leaves a partial output in the store — run long builds
  in the foreground with a `timeout`, not `nohup … &`.
- **GPU pinning (single router, still Vulkan).** The mesa
  device-select layer (`VK_LAYER_MESA_device_select`, an implicit layer
  auto-loaded by every Vulkan app because NixOS patches the loader's search
  paths to `/run/opengl-driver/share`) reorders Vulkan devices so the
  **boot-VGA (console) GPU comes first** when `MESA_VK_DEVICE_SELECT` is unset.
  The R9700 drives no screens — the console lives on the iGPU — so `-dev
  Vulkan0` used to silently mean the Vega (that is how the r9700's models once
  ended up on the iGPU's GTT). Fix in `hosts/zen3-nixos/ai/llama-swap.nix`:
  the r9700 router wrapper sets `XDG_DATA_DIRS=/run/opengl-driver/share` and
  `MESA_VK_DEVICE_SELECT=1002:7551!`; the trailing `!` exposes only that device,
  so `-dev Vulkan0` always means the pinned GPU. The HIP-fork era is over
  (`HIP_VISIBLE_DEVICES`, `HSA_OVERRIDE_GFX_VERSION` are gone). Don't
  "simplify" this back to plain indices.

- **CPU swap 2026-10-08 (5700G → 5950X): the PCIe bus re-enumerated, so BDFs and
  render minors are NOT stable.** The R9700 moved `0000:03:00.0`→`0000:09:00.0`
  (renderD128→renderD129) and the RX 580 `06:00.0`→`04:00.0` (it owns
  renderD128 now and is the console — the 5950X has **no iGPU**, so every
  "Vega iGPU" note in this file is history). `03:00.0` is now an AMD-500-series
  switch port, which is why `gpu-panel` crash-looped on a hardcoded BDF and
  `gpu.ai.chrisdell.info` 502'd. **Match GPUs by PCI id/UUID, never a BDF or a
  renderD minor**: `gpu-panel --pci 1002:7551` (id-based sysfs scan), the R9700's
  DRM node via the udev symlink `/dev/dri/r9700` (`services.udev.extraRules` in
  `hosts/zen3-nixos/ai/gpu-panel.nix`), HIP by `amd-smi list` UUID
  `47ff7551-…`. One swap side effect still open: the **TPM changed**, which had
  invalidated libvirt's sealed `secrets-encryption-key` and made every
  `nixos-rebuild switch` exit 4 (regenerated 2026-10-08; the old blob is kept as
  `/var/lib/libvirt/secrets/secrets-encryption-key.stale-tpm`).
  The other side effect is **fixed (2026-10-08, box rebooted 23:26 BST): ReBAR is back on** — Above-4G
  Decoding + Re-Size BAR enabled in the BIOS, so `lspci -vvvs 09:00.0` shows
  `BAR 0: current size: 32GB, supported: 256MB 512MB 1GB 2GB 4GB 8GB 16GB 32GB`
  mapped at `f000000000`, and amdgpu logs `Detected VRAM RAM=32624M, BAR=32768M`
  (was `BAR=256M` after the swap) — the whole card is host-visible, no 256 MB
  window. If BAR0 reads 256 MB again, the BIOS setting got reset.

- **The r9700 HIP fork is gone (all llama.cpp forks removed 2026-09-26).**
  `rdna-boosts`/`llama-cpp-rdna` (stew675) was the r9700 build until
  2026-08-23 (zero MTP draft acceptance on HIP: spec_decode counters stayed 0);
  `llama-cpp-mtp` (local `/home/cjdell/Projects/llama-mtp`) carried the open
  qwen4exp-MTP PRs from 2026-09-03; `llama-cpp-uma` was an unused local
  checkout of upstream. All three inputs are deleted from `flake.nix` — the
  router runs upstream `llama-cpp` (Vulkan) only. The checkouts are still on
  disk for reference. The old build recipe was: `rocm` overridden to
  `rocmGpuTargets = "gfx1201"` + `-DLLAMA_BUILD_TESTS=OFF` (upstream's flake
  builds the full test suite and parallel test compilation ICEs gcc on
  test-jinja.cpp). Benchmarks: `scripts/bench-r9700.sh` /
  `bench-compare.sh`, results in `bench-results/r9700/`.

- **`sudo nginx -T`/`-t` is misleading *and* has a side effect.** It reads the
  package's stock `conf/nginx.conf` unless you pass the generated one, so the
  documented invocation is
  `sudo nginx -T -c "$(systemctl cat nginx | grep -oE '/nix/store/[a-z0-9]+-nginx\.conf' | head -1)"`
  (the older `/run/current-system/etc/systemd/system/nginx.service/nginx.service`
  path is **not a directory** any more — grep fails with "Not a directory" and
  the command runs with no config at all). ⚠️ **The side effect:** NixOS emits
  no `user` directive, so a root-run nginx chowns every `*_temp_path` dir under
  `/var/cache/nginx` to its unset-user fallback **`nobody` (65534), mode 0700**.
  The worker (uid 60) then cannot create the client-body spill file, and every
  request with a body over `client_body_buffer_size` (i.e. every agent prompt)
  gets a bare `500` with `[crit] open()
  "/var/cache/nginx/client_body_temp/00000000NN" failed (13: Permission denied)`
  in the **journal** (the generated config sets `error_log stderr;`, so there is
  no `/var/log/nginx/error.log` to grep on the live service). This took out every
  pi session on 2026-10-15 (22:57–23:04, right after a post-deploy `nginx -t`).
  Recover without a rebuild:
  `sudo find /var/cache/nginx -mindepth 1 -maxdepth 1 -exec chown nginx:nginx {} +`
  (use `sudo find`, not `sudo ls /var/cache/nginx/*` — that glob expands in your
  own shell and the dir is 0750 nginx:nginx). `hosts/zen3-nixos/nginx.nix` now
  fixes it at the source: it declares `user nginx;` in the main context (nginx
  warns "the \"user\" directive makes sense only if the master process runs with
  super-user privileges, ignored" once per start — expected, don't remove it) and
  keeps the spill dirs `0770 nginx:nginx`, so a wrong owner no longer locks the
  worker out. On any *other* host (no `user` directive in its config), run root
  tests as `sudo nginx -t -c <conf> -g 'user nginx nginx;'`.
- The NixOS nginx unit runs `daemon off` under systemd (foreground).
  Standalone nginx tests need patched `pid`/`error_log`/`access_log` paths,
  ports, and `setsid`/`nohup` to background.
- The `llama-log-viewer` systemd service runs **as root** because
  `/home/cjdell` is `700` — a non-root user cannot read
  `/home/cjdell/nixos-config/llama-logs`.
- `python3` is **not** on PATH; use `nix shell nixpkgs#python3 --command …`.
- Rust: `cargo 1.95` is on PATH but `rustc` is broken; use
  `rustup run stable cargo build --release` with the gcc wrapper from the
  system (`PATH=/nix/store/<gcc-wrapper>/bin:$PATH`) if you must build the app
  outside Nix. Prefer `nixos-rebuild` to build the packaged binary.
- The nginx `/logs` route strips its prefix with an explicit rewrite
  (`rewrite ^/logs/?(.*)$ /$1 break;` + `proxy_pass http://127.0.0.1:8083;`).
  The earlier trailing-slash `proxy_pass …/;` variant was observed *not* to
  strip on the live master; the explicit rewrite is the form that works.

- **Partition layout / NVMe naming:** `/` is on the WD Black p3 (250G, at the *end* of the disk), `/home` on p5 (~681G), `/boot` the ESP (548M). There are two NVMe drives and their kernel names (`nvme0n1`/`nvme1n1`) **swap between boots** — always resolve by fs UUID (`4424123b…`=/, `a4284946…`=/home, `F281-1075`=ESP), never by device path.
- **`resize-once.nix` is a disabled one-shot initrd resize** (completed 2026-08-14: / 181G->250G, /home 750G->681G). Import commented out in `default.nix`; full write-up + reuse steps in `docs/resize-once.md`.
- **The ESP fills up** as generations accumulate (each initrd ~65MB); prune the system profile (`nix-env --profile /nix/var/nix/profiles/system --delete-generations +N`) to keep the 548M ESP bootable.

