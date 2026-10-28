# asus-i7-6700-nixos as a folding@home space heater — CPU AND BOTH GPUs,
# flat out (proper ATX PSU since the 2026-10-28 rebuild; the HP Z240-era
# derate — cpus=4, 50 % GPU duty, 100 W nvidia-smi caps, 90 s boot delay —
# is removed).
#
# CPU: the i7-6700 is 4 Skylake cores / 8 threads with AVX2 (65 W TDP).
#
# GPUs: GeForce GTX 1060 6GB (GP106/Pascal, CC 6.1) + GTX 970 (GM204/
# Maxwell, CC 5.2), both folded via the NVIDIA driver:
#
#   * FAH v8 detects cards through OpenCL and runs the work units on the
#     OpenMM core's CUDA platform — both cards enumerate as CUDA devices
#     (verified live 2026-10-28: "Platform: CUDA", DeviceIndex 0 = 1060,
#     1 = 970). Detection still needs an OpenCL device with fp64 +
#     cl_khr_pci_bus_info (fah-client-bastet#239); the 580-branch ICD
#     provides it for both, so the client flips their gpus.json entries
#     (10de:1c03, 10de:13c2 — both in the FAH database) to supported and
#     fah-provision enables the slots.
#   * Maxwell/Pascal are EOL'd by the main driver branches (590+ dropped
#     them), hence hardware.nvidia.package = legacy_580 in
#     ./hardware-configuration.nix. The nvidia-x11 package installs its
#     ICD registration at $out/etc/OpenCL/vendors/nvidia.icd (absolute
#     store path inside), so pointing OCL_ICD_VENDORS at it is the whole
#     wiring — same trick as haswellatx-nixos uses for Mesa's rusticl.icd.
#   * libcuda.so.1 + libnvidia-ml.so.1 go on LD_LIBRARY_PATH from the same
#     package dir: OpenMM prefers its CUDA plugin, and NVML is how the
#     client reads utilisation for Web Control.
#
# Web Control: http://192.168.49.65:7396/ ; the sops account token also links
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
    # NOTE: config.xml only SEEDS the client — its SQLite DB keeps prior
    # settings. The box came over from the derated HP config (cpus=4,
    # gpu-usage=50 in the DB), so the DB was wiped once at the rename to
    # let the values below re-seed. cpus/gpuUsage stay explicit (not null)
    # so a future wipe re-seeds the flat-out values too.
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
    # app.foldingathome.org next to zen1 and haswellatx). secrets/fah.yaml is
    # encrypted to the shared fleet age key, i.e. the
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
  # unauthenticated on port 80 — http://192.168.49.65/ — matching how the
  # FAH Web Control on :7396 is exposed here. The nvidia backend samples
  # every GPU (power summed across the 1060 + 970 for the load card), and
  # its cap slider sets the same limit on both cards (shared nvidia-smi -pl
  # without -i) — an emergency throttle knob, not per-card tuning. No
  # boot-time power caps and no budget marker here: unlike the old
  # PSU-crippled HP, the DC estimate has nothing to watch against.
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
