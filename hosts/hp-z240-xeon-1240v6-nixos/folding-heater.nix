# hp-z240-xeon-1240v6-nixos as a folding@home space heater — CPU AND GPU.
# (Currently deliberately DERATED — see the ⚠️ block in the config below.)
#
# CPU: the Xeon E3-1240 v6 is 4 Kaby Lake cores / 8 threads with AVX2
# (80 W TDP).
#
# GPU: the GeForce GTX 970 (GM204/Maxwell, CC 5.2) folds through the
# NVIDIA driver's own OpenCL ICD — the same ocl-icd mechanism the AMD
# heaters use, just with the vendor ICD instead of the ROCm/Rusticl one:
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
# Known rough edge: Maxwell GPU WUs are the older/smaller OpenMM ones —
# slower per card than anyone's Pascal+ box, but ~10x the CPU slot's PPD
# and the whole point of a heater. Watch the first WU in the log
# (gpu_busy_percent via nvidia-smi should pin near 100).
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
  imports = [ ../../common/folding-at-home-native.nix ];

  services.folding-at-home-native = {
    enable = true;
    userName = "cjdell";
    teamNumber = 236565;
    # ⚠️ Throttled (was cpus = 8, full GPU) after 2026-10-25: with folding
    # enabled the box HARD-RESETS ~2 s after the client spins up its slots
    # during boot (journal ends at +20 s with no MCE/panic, three boots in
    # a row; a boot without folding survives, and once up it had folded
    # full-tilt for 9.5 min without complaint). Root cause confirmed by
    # measurement: the SFF PSU browns out on the combined CPU+GPU load step
    # — made worse than it looks by a loose CPU heatsink (found + reseated
    # 2026-10-25; with it seated the CPU finally draws its real power,
    # which is what pushes the rail over the edge — the 99-100 C readings
    # were the loose mount, not the cooler being insufficient). The 120 W
    # nvidia-power-limit unit below is the hard ceiling; this derate keeps
    # the boot-time step itself survivable: fewer CPU slots (biggest boot
    # spike), GPU at 50 % duty, and start folding only after boot has
    # settled. Re-ramp one step at a time across a few reboots — and until
    # the SATA->PCIe adapter is swapped for Molex, do not trust full power.
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

  # Hardware power cap for the GTX 970 — NVML accepts -pl on this card
  # (verified 2026-10-25: "set to 120.00 W from 200.00 W"), so the ceiling
  # is real, not a duty-cycle like gpuUsage. Caps the CUDA-init spike too,
  # which gpu-usage cannot reach. 120 W ≈ three quarters boost; it is not
  # persisted by the driver, so re-apply every boot before fah starts.
  # Raise/remove together with the gpuUsage derate in the block above.
  # Hardware power cap for the GTX 970 — NVML accepts -pl on this card
  # (verified 2026-10-25: "set to 120.00 W from 200.00 W"), so the ceiling
  # is real, not a duty-cycle like gpuUsage. Caps the CUDA-init spike too,
  # which gpu-usage cannot reach. 120 W ≈ three quarters boost; it is not
  # persisted by the driver, so re-apply every boot before fah starts.
  # Raise/remove together with the gpuUsage derate in the block above.
  systemd.services.nvidia-power-limit = {
    description = "Cap GTX 970 power at 120 W (nvidia-smi -pl)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "fah-client.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # The modules appear asynchronously; retry until NVML answers.
      Restart = "on-failure";
      RestartSec = "5s";
      ExecStart = "${config.hardware.nvidia.package}/bin/nvidia-smi -pl 120";
    };
  };

  # fah-panel — the folding box's sibling of zen3's gpu-panel (see
  # crates/fah-panel): live GPU (nvidia-smi) + CPU (sysfs) telemetry with a
  # power-cap slider, the dashboard for "is it folding and is it brownout-
  # adjacent". Unauthenticated LAN UI at http://192.168.49.65:7397/ —
  # matching how the FAH Web Control on :7396 is exposed here.
  systemd.services.fah-panel =
    let
      panel = pkgs.rustPlatform.buildRustPackage {
        pname = "fah-panel";
        version = "0.1.0";
        src = ../../crates/fah-panel;
        cargoLock.lockFile = ../../crates/fah-panel/Cargo.lock;
        doCheck = false;
      };
    in
    {
      description = "Folding heater telemetry panel (GTX 970 + CPU)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "nvidia-power-limit.service" ];
      serviceConfig = {
        # Runs as root: RAPL energy_uj is mode 0400 and the panel's
        # nvidia-smi -pl control needs root too. --budget 180 W flags the
        # CPU+GPU DC estimate against this box's reality: the PSU adds
        # ~30-40 W of board/SSD/fans on top of what the panel sums, the
        # derated steady state lands ~150 W, and the brownout trips came
        # from steps toward ~230 W. Rail voltages are NOT readable here:
        # the HP Super-I/O exposes only a dead pwm1 and there is no BMC —
        # the DC estimate is the closest software proxy (a multimeter or
        # an INA226 inline monitor on the GPU adapter line is the real
        # instrument).
        ExecStart = "${panel}/bin/fah-panel --listen 0.0.0.0:7397 --nvidia-smi ${config.hardware.nvidia.package}/bin/nvidia-smi --budget 180";
        Restart = "always";
        RestartSec = 5;
      };
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
