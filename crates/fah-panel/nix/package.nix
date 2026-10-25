{ lib, rustPlatform }:

# The one heater-panel binary for every folding box; enabled per host by
# common/fah-panel.nix (which supplies the backend selection). Zero deps —
# std only, frontend embedded via include_str!, so any frontend change
# rebuilds the binary.
rustPlatform.buildRustPackage {
  pname = "fah-panel";
  version = "0.1.0";
  src = ../.;
  cargoLock.lockFile = ../Cargo.lock;
  doCheck = false;

  meta = with lib; {
    description = "Folding heater telemetry web panel: NVIDIA (nvidia-smi) or AMD (amdgpu sysfs) GPU + CPU (sysfs), with a live power-cap slider";
    mainProgram = "fah-panel";
    platforms = platforms.linux;
  };
}
