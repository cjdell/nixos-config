# haswellatx-nixos as a folding@home space heater — CPU AND GPU.
#
# CPU: the i5-4460 is 4 Haswell threads with AVX2 (FahCore_a8, ~84 W TDP);
# the client runs all four until it auto-reserves one for the GPU slot
# (observed: -np 3 + GPU).
#
# GPU: the Radeon R9 290/390 (Hawaii PRO, GCN2 / gfx700, 0x67b1) cannot use
# ROCm — AMD dropped gfx700 compute in 2018 (ROCm 2.0, ROCm/ROCm#871) — but
# it DOES fold via **Mesa's Rusticl**, an OpenCL 3.1 implementation that
# runs on radeonsi compute queues without ROCm/KFD:
#
#   * gfx700 is supported-but-unofficial in Rusticl (works since ~Mesa 25.x;
#     the box's radeonsi display already ran it: `amdgpu.cik_support=1` in
#     ./hardware-configuration.nix, kernel >= 6.18 drives Hawaii on amdgpu).
#   * RUSTICL_ENABLE takes GALLIUM DRIVER NAMES (source
#     rusticl/mesa/pipe/device.rs:74) — `radeonsi`. Older blog posts saying
#     `AMD` are wrong for current Mesa: an unknown token just disables every
#     device (that is how you end up with a "rusticl platform, 0 devices").
#   * fp64 is compiled in but OFF by default (Rusticl's OpenMM/FAH-relevant
#     caveat; enable with RUSTICL_FEATURES=fp64, core/platform.rs:152).
#   * What fah-client actually requires from an OpenCL device (confirmed by
#     FAH dev jcoffland in fah-client-bastet#239): OpenCL >= 1.2 + fp64 +
#     `cl_khr_pci_bus_info` (or CL_DEVICE_TOPOLOGY_AMD) so the CL device can
#     be matched to its PCI slot. Rusticl on Hawaii has all three; the
#     client then flips its own gpus.json entry
#     ("Hawaii PRO [R9 290/390]" = 0x67b1 — it has always been in the FAH
#     database) from `supported: false` and hands out GPU work.
#   * The core is FahCore_28 (openmm-core-28): it tries the HIP plugin
#     first, logs "Error loading plugin libOpenMMHIP.so: libhiprtc.so.6..."
#     and "hip-device was set but HIP platform could not be found" —
#     harmless; it then falls back to OpenCL: "GPU info: Platform: OpenCL:
#     rusticl ... (radeonsi, hawaii)". Measured: WU P18295 (5M steps) at
#     ~2.2k steps/s = ~37 min/WU, gpu_busy_percent 100, ~49 C at idle load.
#
# Known rough edges of the unofficial path: Rusticl on gfx700 is
# best-effort (kernel hangs would surface as a failed core/assignment, not
# corruption — OpenMM checkpoints); per-buffer allocations cap at 1 GiB on
# this driver, which current GPU WUs fit. Keep the driver honest by not
# pulling "cleanups" to the env below.
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
  imports = [ ../../common/folding-at-home-native.nix ];

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

  # Swap the module's ROCm OpenCL ICD (useless here: no /dev/kfd, gfx700 is
  # not in any ROCm since 2.x) for Mesa's Rusticl and turn it on for Hawaii.
  # fah-client dlopens libOpenCL.so.1 via the LD_LIBRARY_PATH the module
  # already sets; ocl-icd loads <dir>/rusticl.icd by absolute path.
  systemd.services.fah-client.environment = {
    OCL_ICD_VENDORS = lib.mkForce "${pkgs.mesa.opencl}/etc/OpenCL/vendors";
    RUSTICL_ENABLE = "radeonsi";
    RUSTICL_FEATURES = "fp64";
    # The fah user's HOME is /var/empty (isSystemUser), so Mesa's disk cache
    # — the LLVM-compiled OpenMM kernels, dozens per WU start — would be
    # rebuilt from scratch on every service restart. Give it a writable home.
    XDG_CACHE_HOME = "/var/cache/fah-client";
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
