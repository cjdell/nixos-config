# hp-z240-xeon-1240v6-nixos as a folding@home space heater — CPU AND GPU,
# FLAT OUT (adoption decision 2026-11-14).
#
# ⚠️ PSU HISTORY YOU ARE OVERRULING: the FIRST Z240 SFF of this exact model
# (the old .65 box, now asus-i7-6700-nixos) hard-reset under combined
# CPU+GPU folding load — the 240 W SFF PSU brown-out was measured, and that
# box ended its life derated: 100 W nvidia-smi cap, cpus=4, gpuUsage=50, a
# 90 s start delay and a 180 W panel budget. This is a different chassis
# (xHCI verified working, NVMe not the old SATA-on-adapter build), and the
# operator chose flat-out from day one on it. If this box ever hard-resets
# under load, do NOT hunt in the kernel: re-apply the proven derate — the
# whole recipe (nvidia-power-limit unit + cpus=4/gpuUsage=50/startDelay +
# budget) is in git:
#   git show ff7e54b^:hosts/hp-z240-xeon-1240v6-nixos/folding-heater.nix
#
# CPU: the Xeon E3-1240 v6 is 4 Kaby Lake cores / 8 threads with AVX2
# (80 W TDP). All 8 threads fold.
#
# GPU: the GeForce GTX 970 (GM204/Maxwell, CC 5.2) folds through the
# NVIDIA driver's own OpenCL ICD — the same ocl-icd mechanism the AMD
# heaters use, just with the vendor ICD instead of the ROCm/Rusticl one
# (this box has no AMD GPU; the module's ROCm ICD default is overridden
# below):
#
#   * FAH v8 requires OpenCL >= 1.2 + fp64 + cl_khr_pci_bus_info from an
#     OpenCL device (fah-client-bastet#239); the 580-branch ICD on GM204
#     has all three, so the client flips its gpus.json entry for
#     10de:13c2 (which is in the FAH database) to supported and
#     fah-provision enables the slot.
#   * Maxwell is EOL'd by the main driver branches (590+ dropped it), hence
#     hardware.nvidia.package = legacy_580 in ./hardware-configuration.nix.
#     The nvidia-x11 package installs its ICD registration at
#     $out/etc/OpenCL/vendors/nvidia.icd (absolute store path inside), so
#     pointing OCL_ICD_VENDORS at it is the whole wiring — same trick as
#     haswellatx-nixos uses for Mesa's rusticl.icd.
#   * libcuda.so.1 + libnvidia-ml.so.1 go on LD_LIBRARY_PATH from the same
#     package dir: OpenMM prefers its CUDA plugin, and NVML is how the
#     client reads utilisation for Web Control.
#
# NOTE (fleet-wide): config.xml only SEEDS the client — its SQLite DB keeps
# prior settings, so changing cpus/gpuUsage below on a live box needs the DB
# wiped (rm /var/lib/fah-client/db.sql.fah + state, then restart) or the
# change made live in Web Control / fahctl.
#
# Web Control: http://192.168.49.59:7396/ ; the sops account token also links
# the machine into the FAH account (see the accountTokenFile below).
# Progress: `journalctl -u fah-client -f` or `tail /var/lib/fah-client/log.txt`.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ../../common/fah-panel.nix
    ../../common/folding-at-home-native.nix
  ];

  services.folding-at-home-native = {
    enable = true;
    userName = "cjdell";
    teamNumber = 236565;
    cpus = 8;
    gpuUsage = 100;
    httpAddresses = [ "0.0.0.0:7396" ];
    allowAddresses = [
      "127.0.0.1" # loopback — fah-provision and local fahctl connect here
      "::1"
      "192.168.49.0/24" # LAN
      "10.47.0.0/16" # WireGuard
      "100.64.0.0/10" # tailnets
    ];
    # Links this machine to the FAH account (it then shows up in
    # app.foldingathome.org next to zen1, haswellatx and asus-i7-6700).
    # secrets/fah.yaml is encrypted to the shared fleet age key, i.e. the
    # /var/lib/sops-nix/key.txt provisioned on every sops-enabled host.
    accountTokenFile = config.sops.secrets.fah_account_token.path;
  };

  sops.secrets.fah_account_token = {
    sopsFile = ../../secrets/fah.yaml;
    restartUnits = [ "fah-client.service" ];
  };

  # Swap the module's ROCm OpenCL ICD (useless here — no AMD GPU) for the
  # NVIDIA driver's, and give the core the driver's own libraries.
  systemd.services.fah-client.environment = lib.mkIf config.services.folding-at-home-native.enable {
    OCL_ICD_VENDORS = lib.mkForce "${config.hardware.nvidia.package}/etc/OpenCL/vendors";
    LD_LIBRARY_PATH = lib.mkForce (
      lib.makeLibraryPath [
        pkgs.ocl-icd
        pkgs.expat
        pkgs.zlib
        config.hardware.nvidia.package
      ]
    );
    # The fah user's HOME is /var/empty (isSystemUser), and the NVIDIA
    # userspace keeps its JIT'd compute-kernel cache under $HOME/.nv —
    # point HOME into the CacheDirectory so kernels are not recompiled on
    # every service restart.
    HOME = "/var/cache/fah-client";
  };

  systemd.services.fah-client.serviceConfig.CacheDirectory = "fah-client";

  # fah-panel — the folding box's sibling of zen3's gpu-panel (see
  # crates/fah-panel, service module common/fah-panel.nix): live GPU
  # (nvidia-smi) + CPU (sysfs) telemetry with a power-cap slider, served
  # unauthenticated on port 80 — http://192.168.49.59/ — matching how the
  # FAH Web Control on :7396 is exposed here. No --budget marker (flat-out
  # decision), but the 970's power-cap slider IS the brown-out lever if
  # resets ever appear — the old box proved NVML accepts -pl on GM204.
  services.fah-panel = {
    enable = true;
    gpu = "nvidia";
    nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
  };

  # A heater never sleeps; logind refuses suspend/hibernate requests
  # (PowerDevil's idle actions included).
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
}
