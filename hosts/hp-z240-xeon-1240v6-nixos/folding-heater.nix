# hp-z240-xeon-1240v6-nixos as a folding@home space heater — CPU AND GPU,
# DERATED to the recipe the FIRST Z240 SFF of this model proved survivable.
#
# ⚠️ FLAT-OUT WAS TRIED AND MEASURED DEAD, here, 2026-11-14 (adoption day):
# the installed system booted 00:52:15 with cpus=8 + the GPU slot uncapped and
# HARD-RESET TWICE, at +101 s and +130 s — both journals end mid-line with no
# shutdown sequence, no panic, no MCE, once while extracting FahCore_28's
# libnvrtc .so files and once mid OpenCL/CUDA platform enumeration (the exact
# spin-up load step). Old box, new box, same failure (+90..121 s at boot
# spin-up), same 240 W SFF PSU. The third boot only survived because the
# client had stopped the cores after the WU dumps. So: this box folds to the
# proven recipe below; the fah-panel power-cap slider is the live re-ramp
# lever, one step per few reboots, with nvidia-smi's -pl ceiling as the hard
# limit. Do not remove the nvidia-power-limit unit to "try flat again" without
# watching the first three boots.
#
# The old Z240's history (same model, .65, ended its life at exactly these
# numbers after also failing once 7 min INTO folding at a real 120 W cap —
# see git ff7e54b^ for the full write-up): 100 W cap + cpus=4 + gpuUsage=50 +
# 90 s start delay is the combination that held.
#
# CPU: the Xeon E3-1240 v6 is 4 Kaby Lake cores / 8 threads with AVX2
# (80 W TDP); only 4 threads fold — the boot spike of the 8-thread step is
# what the rail cannot take.
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
#   * Verified live at adoption: the client started FahCore_27/28 on
#     "Platform: CUDA, Device: NVIDIA GeForce GTX 970, Compute 5.2" — the
#     slot wiring works; only the POWER was the problem.
#
# NOTE (fleet-wide): config.xml only SEEDS the client — its SQLite DB keeps
# prior settings, so changing cpus/gpuUsage below on a live box needs the DB
# wiped (rm /var/lib/fah-client/db.sql.fah + state, then restart) or the
# change made live in Web Control / fahctl. (Adoption note: the DB was born
# here with the flat-out cpus=8 seed and was wiped when this derate landed.)
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
    # Derated (see header): fewer CPU slots (biggest boot spike), GPU at
    # 50 % duty, and folding only starts once boot has settled. The 100 W
    # nvidia-power-limit unit below is the lever that actually holds.
    cpus = 4;
    gpuUsage = 50;
    startDelay = "90";
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

  # Hardware power cap for the GTX 970 — NVML accepts -pl on this card (the
  # old box proved it: "set to 120.00 W from 200.00 W"), so the ceiling is
  # real, not a duty-cycle like gpuUsage. Caps the CUDA-init spike too,
  # which gpu-usage cannot reach. It is not persisted by the driver, so
  # re-apply every boot before fah starts. 100 W = the number the first
  # Z240 survived on (at a real 120 W it still reset 7 min into folding,
  # 38 s after a WU step boundary — 2026-10-25 history, git ff7e54b^).
  systemd.services.nvidia-power-limit = {
    description = "Cap GTX 970 power at 100 W (nvidia-smi -pl)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "fah-client.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # The modules appear asynchronously; retry until NVML answers.
      Restart = "on-failure";
      RestartSec = "5s";
      ExecStart = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi -pl 100";
    };
  };

  # fah-panel — the folding box's sibling of zen3's gpu-panel (see
  # crates/fah-panel, service module common/fah-panel.nix): live GPU
  # (nvidia-smi) + CPU (sysfs) telemetry with a power-cap slider, the
  # dashboard for "is it folding and is it brownout-adjacent". Unauthenticated
  # LAN UI on port 80 — http://192.168.49.59/ — matching how the FAH Web
  # Control on :7396 is exposed here. (zen1 runs the same app with its
  # --gpu amd backend.)
  services.fah-panel = {
    enable = true;
    gpu = "nvidia";
    nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
    # --budget 180 W flags the CPU+GPU DC estimate against this box's reality
    # (same numbers as the old Z240: ~30-40 W of board/SSD/fans above what
    # the panel sums, derated steady state ~150 W, brown-out trips came from
    # steps toward ~230 W). Rail voltages are NOT readable here — the DC
    # estimate is the closest software proxy.
    budget = 180;
  };

  # The panel reads/pins the cap the boot-time unit owns, so start after it.
  systemd.services.fah-panel.after = [ "nvidia-power-limit.service" ];

  # A heater never sleeps; logind refuses suspend/hibernate requests
  # (PowerDevil's idle actions included).
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
}
