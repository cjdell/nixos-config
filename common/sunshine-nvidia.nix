{
  config,
  pkgs,
  ...
}:

{
  # Enable nvenc support. `cudaSupport` now covers what this module used to
  # patch in by hand: nixpkgs' sunshine builds with cudaPackages.backendStdenv
  # and adds cuda_nvcc + cuda_cudart.dev itself (pkgs/by-name/su/sunshine/
  # package.nix:65,179-182) and leaves SUNSHINE_ENABLE_CUDA on, so the extra
  # nativeBuildInputs/cmakeFlags overrideAttrs that used to sit here were
  # duplicates. Sunshine's own closure is just those two CUDA packages — the
  # rest of the toolkit was never needed at runtime (verified: the sunshine
  # drv's only CUDA inputs are cuda13.4-cuda_cudart and cuda13.4-cuda_nvcc).
  services.sunshine.package = pkgs.sunshine.override {
    cudaSupport = true;
    cudaPackages = pkgs.cudaPackages;
  };

  # The driver libraries Sunshine has to see at runtime. This has to follow the
  # package the host actually loads, not nvidiaPackages.latest: hosts pin
  # branches (hosts/asus-i7-6700-nixos is on legacy_580 for its Maxwell card),
  # and 615 userspace libraries against a 580 kernel module is a driver
  # mismatch. `.out` is the output that carries lib/.
  systemd.user.services.sunshine.serviceConfig.Environment =
    "LD_LIBRARY_PATH=${config.hardware.nvidia.package.out}/lib:${config.hardware.nvidia.package.out}/lib64";

  # This module used to also put pkgs.cudaPackages.cudatoolkit in
  # environment.systemPackages. Dropped 2026-11-03: cudatoolkit is the MERGED
  # CUDA set, and on this nixpkgs pin (patchelf 0.19.2, NixOS/patchelf#674,
  # NixOS/nixpkgs#576412) cuda_gdb and cuda_sanitizer_api cannot be built at
  # all — autoAddDriverRunpath dies with `Assertion 'splitIndex == -1' failed`
  # on cuda-gdbserver and compute-sanitizer's TreeLauncherSubreaper — so the
  # whole system path stopped being buildable (no substitute either: Hydra
  # fails the same way). Nothing here needs the toolkit in the system path; see
  # the patchelf section of AGENTS.md for restoring it if that ever changes.
}
