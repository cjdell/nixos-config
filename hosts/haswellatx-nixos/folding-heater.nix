# haswellatx-nixos as a folding@home space heater — CPU AND GPU.
#
# CPU: the i5-4460 is 4 Haswell threads with AVX2 (FahCore_a8, ~84 W TDP);
# the client runs all four until it auto-reserves one for the GPU slot
# (observed: -np 3 + GPU).
#
# GPU: GeForce GTX 970 (GM204/Maxwell, CC 5.2, 0x13c2 — swapped for the R9
# 290/390, Hawaii PRO (GCN2 / gfx700), that Rusticl had been folding on) —
# folded via the NVIDIA driver, the same proven wiring as
# asus-i7-6700-nixos (hosts/asus-i7-6700-nixos/folding-heater.nix).
#
# Web Control: http://192.168.49.54:7396/ ; the sops account token also links
# the machine into the FAH account (see the accountTokenFile below).
# Progress: `journalctl -u fah-client -f` or `tail /var/lib/fah-client/log.txt`.
{ config, ... }:

{
  imports = [
    ../../common/folding-heater.nix
    ../../common/fah-nvidia.nix
  ];

  services.folding-at-home-native = {
    cpus = 4; # the whole i5-4460; the client itself reserves one for the GPU slot
  };

  # The heater's web power gui (crate crates/fah-panel + common/fah-panel.nix,
  # the same module as asus-i7-6700): live GPU (util/temp/power) + CPU
  # graphs and the GPU power-cap slider, served unauthenticated on port 80 —
  # http://192.168.49.54/ — next to the FAH Web Control on :7396.
  services.fah-panel = {
    gpu = "nvidia";
    nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
  };
}
