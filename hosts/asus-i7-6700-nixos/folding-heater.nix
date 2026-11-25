# asus-i7-6700-nixos as a folding@home space heater — CPU AND BOTH GPUs,
# flat out (proper ATX PSU since the 2026-10-28 rebuild; the HP Z240-era
# derate — cpus=4, 50 % GPU duty, 100 W nvidia-smi caps, 90 s boot delay —
# is removed).
#
# CPU: the i7-6700 is 4 Skylake cores / 8 threads with AVX2 (65 W TDP).
#
# GPUs: GeForce GTX 1060 6GB (GP106/Pascal, CC 6.1) + GTX 970 (GM204/
# Maxwell, CC 5.2), both folded via the NVIDIA driver.
#
# Web Control: http://192.168.49.65:7396/ ; the sops account token also links
# the machine into the FAH account (see the accountTokenFile below).
# Progress: `journalctl -u fah-client -f` or `tail /var/lib/fah-client/log.txt`.
{ config, ... }:

{
  imports = [
    ../../common/folding-heater.nix
    ../../common/fah-nvidia.nix
  ];

  services.folding-at-home-native = {
    # NOTE: config.xml only SEEDS the client — its SQLite DB keeps prior
    # settings. The box came over from the derated HP config (cpus=4,
    # gpu-usage=50 in the DB), so the DB was wiped once at the rename to
    # let the values below re-seed. cpus/gpuUsage stay explicit (not null)
    # so a future wipe re-seeds the flat-out values too.
    cpus = 8;
    gpuUsage = 100;
  };

  # fah-panel — the folding box's sibling of zen3's gpu-panel (see
  # crates/fah-panel, service module common/fah-panel.nix): live GPU
  # (nvidia-smi) + CPU (sysfs) telemetry with a power-cap slider, served
  # unauthenticated on port 80 — http://192.168.49.65/ — matching how the
  # FAH Web Control on :7396 is exposed here. The nvidia backend shows one
  # live card + one cap slider PER GPU (1060 and 970, each with its own
  # nvidia-smi -i N -pl range), and the DC-load card sums both boards with
  # the CPU. No boot-time power caps and no budget marker here: unlike the
  # old PSU-crippled HP, the DC estimate has nothing to watch against.
  services.fah-panel = {
    gpu = "nvidia";
    nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
  };
}
