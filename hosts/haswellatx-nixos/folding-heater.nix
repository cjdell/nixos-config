# haswellatx-nixos as a folding@home space heater — CPU AND GPU.
#
# CPU: the i5-4460 is 4 Haswell threads with AVX2 (FahCore_a8, ~84 W TDP);
# the client runs all four until it auto-reserves one for the GPU slot
# (observed: -np 3 + GPU).
#
# GPU: GeForce GTX 970 (GM204/Maxwell, CC 5.2, 0x13c2 — swapped for the R9
# 290/390, Hawaii PRO (GCN2 / gfx700), that Rusticl had been folding on) —
# folded via the NVIDIA driver, the same proven wiring as
# asus-i7-6700-nixos (hosts/asus-i7-6700-nixos/folding-heater.nix):
#
#   * FAH v8 detects cards through OpenCL and runs the work units on the
#     OpenMM core's CUDA platform (DeviceIndex 1 on asus) — the 970 is
#     supported by the legacy_580 driver branch (see
#     hardware.nvidia.package in ./hardware-configuration.nix).
#   * Detection still needs an OpenCL device with fp64 +
#     `cl_khr_pci_bus_info` (fah-client-bastet#239); the 580-branch ICD
#     provides it for the 970, so the client flips its gpus.json entry
#     (10de:13c2 — it is in the FAH database) from `supported: false` and
#     fah-provision enables the slot.
#   * libcuda.so.1 + libnvidia-ml.so.1 go on LD_LIBRARY_PATH from the same
#     driver package dir (OpenMM prefers its CUDA plugin, NVML is how the
#     client reads utilisation for Web Control).
#
# Web Control: http://192.168.49.54:7396/ ; the sops account token also links
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
    ../../common/folding-at-home-native.nix
    ../../common/fah-panel.nix
  ];

  services.folding-at-home-native = {
    enable = true;
    userName = "cjdell";
    teamNumber = 236565;
    cpus = 4; # the whole i5-4460; the client itself reserves one for the GPU slot
    httpAddresses = [ "0.0.0.0:7396" ];
    allowAddresses = [
      "127.0.0.1" # loopback — fah-provision and local fahctl connect here
      "::1"
      "192.168.49.0/24" # LAN
      "10.47.0.0/16" # WireGuard
      "100.64.0.0/10" # tailnets
    ];
    # Links this machine to the FAH account (it then shows up in
    # app.foldingathome.org next to zen1). secrets/fah.yaml is encrypted to
    # the shared fleet age key (the *cjdell recipient of .sops.yaml), i.e.
    # the /var/lib/sops-nix/key.txt provisioned on every sops-enabled host.
    accountTokenFile = config.sops.secrets.fah_account_token.path;
  };

  sops.secrets.fah_account_token = {
    sopsFile = ../../secrets/fah.yaml;
    restartUnits = [ "fah-client.service" ];
  };

  # The heater's web power gui (crate crates/fah-panel + common/fah-panel.nix,
  # the same module as asus-i7-6700): live GPU (util/temp/power) + CPU
  # graphs and the GPU power-cap slider, served unauthenticated on port 80 —
  # http://192.168.49.54/ — next to the FAH Web Control on :7396.
  services.fah-panel = {
    enable = true;
    gpu = "nvidia";
    nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
  };

  # Swap the module's ROCm OpenCL ICD (useless here — no AMD GPU) for the
  # NVIDIA driver's, and give the core the driver's own libraries.
  systemd.services.fah-client.environment = {
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

  # A heater never sleeps; logind refuses suspend/hibernate requests
  # (PowerDevil's idle actions included).
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
}
