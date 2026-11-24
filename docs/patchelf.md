> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## patchelf 0.19.2 breaks NVIDIA and CUDA binaries (current pin)

The pinned nixpkgs (`26.11.20261017.09063bd`) ships **patchelf 0.19.2**, which
mangles NVIDIA's prebuilt binaries (NixOS/patchelf#674, NixOS/nixpkgs#576412).
Two unrelated-looking symptoms, both worked around locally — delete both
workarounds once nixpkgs ships the patchelf fix.

- **`nvidia-smi` (and `nvidia-cuda-mps-*`, `nvidia-debugdump`, `nvidia-powerd`)
  segfaults.** nvidia-x11's builder makes one combined
  `patchelf --interpreter … --set-rpath …` call (`builder.sh:203`); the result
  has overlapping LOAD segments with `.dynamic` mapped read-only, so ld.so dies
  with SEGV_ACCERR in `dl_main` before loading any library. The kernel modules
  and the libraries are fine — CUDA, OpenCL and the FAH container all keep
  working while the CLI tools are dead. Tell it apart from a real driver
  problem: a *healthy* `nvidia-smi` on a machine with no NVIDIA driver prints
  "couldn't communicate with the NVIDIA driver" (exit 9); the patchelf one
  dumps core even on zen3, which is AMD — that is the test to run before
  blaming the GPU. Fix: re-patch from the pristine copies the builder keeps in
  `$bin/origBin/`, **rpath first, interpreter second** — carried in
  `hosts/asus-i7-6700-nixos/hardware-configuration.nix` (its `legacy_580` pin)
  and `hosts/kabylakeitx-nixos/hardware-configuration.nix` (`latest`).
- **The merged CUDA set cannot be built at all.** `cudaPackages.cudatoolkit`
  *is* `cuda-merged`, and several of its components trip the same patchelf bug
  inside `autoAddDriverRunpath` —
  `Assertion 'splitIndex == -1' failed` on `compute-sanitizer/TreeLauncherSubreaper`
  and on `cuda-gdbserver` (`cuda_sanitizer_api`, `cuda_gdb`) — which takes the
  whole merged set down with it and makes **any system path containing CUDA**
  unbuildable. No substitute on the cache either: Hydra fails identically, so
  the first sign is a rebuild suddenly trying to compile 70+ CUDA derivations
  and then failing. `common/sunshine-nvidia.nix` therefore no longer puts
  `cudatoolkit` in `environment.systemPackages` (Sunshine needs exactly
  `cuda_nvcc` + `cuda_cudart` at build time and nothing at runtime). If a host
  really wants the toolkit, the hook has a per-component opt-out — re-scope
  with `pkgs.cudaPackages.overrideScope (f: p: { cuda_gdb =
  p.cuda_gdb.overrideAttrs (_: { dontUseAutoAddDriverRunpath = true; }); … })`
  for each component that trips it — but expect more than the two named here,
  and prefer `nix shell` over the system path.

