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
  imports = [
    ../../common/fah-panel.nix
    ../../common/folding-at-home-native.nix
  ];

  services.folding-at-home-native = {
    # ⚠️ HISTORY (2026-10-25): this box HARD-RESETS under folding load.
    # Failure 1-3: at spin-up (+90..121 s). Root fix: the power cap had been
    # failing 203/EXEC since day one (wrong driver output path), so every
    # fah start ran the GPU at its 200 W default. With a REAL 120 W ceiling
    # the spin-up survived — but failure 4 came 7 min into folding, 38 s
    # after a WU step boundary (GPU at 111-120 W, 87-98 % util), i.e. the
    # later transients also exceed what the 240 W SFF PSU / SATA->PCIe
    # adapter can hold. Operator dropped the cap to 100 W on the panel at
    # 18:00; the nvidia-power-limit unit below now encodes 100 W. Testing
    # that at the time of writing.
    # NOTE: config.xml only SEEDS the client — its SQLite DB keeps prior
    # settings, and this client was first started with cpus=8. Observed
    # after re-deploy: FahCore_a8 still runs -np 7 and the 50 % gpu duty
    # cycle is not applied; the cpus/gpuUsage below take effect only after
    # the DB forgets (Web Control / fahctl change it live, or wipe
    # /var/lib/fah-client/db.sql.fah + state). It survived anyway, so the
    # values are kept as the intended re-seed; the 120 W cap is the lever
    # that actually holds. If it trips again: Molex adapter first, then
    # treat the 240 W SFF PSU as insufficient (or enable = false for a
    # CPU-only heater).
    # NOTE: on NixOS the enable state lives in the generated config, NOT in
    # `systemctl disable` — /etc/systemd/system is a read-only symlink farm,
    # so disable fails with EROFS and the unit comes back every boot.
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

  # Hardware power cap for the GTX 970 — NVML accepts -pl on this card
  # (verified 2026-10-25: "set to 120.00 W from 200.00 W"), so the ceiling
  # is real, not a duty-cycle like gpuUsage. Caps the CUDA-init spike too,
  # which gpu-usage cannot reach. It is not persisted by the driver, so
  # re-apply every boot before fah starts.
  # 100 W (was 120) since 2026-10-25 18:00: at a REAL 120 W cap the spin-up
  # survived but the box still hard-reset ~7 min into folding, 38 s after a
  # WU step boundary (journal: "Completed 700000/5000000 steps" then dead)
  # — i.e. the later transients, not just the boot ramp, exceed the 240 W
  # SFF PSU (or the SATA->PCIe adapter sags under sustained ~10 A). The
  # operator set 100 W on the panel slider; this unit encodes it so the
  # choice survives reboots. Escalation if it still trips: Molex adapter
  # swap first, then the PSU is the diagnosis.
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
  # LAN UI on port 80 — http://192.168.49.65/ — matching how the FAH Web
  # Control on :7396 is exposed here. (zen1 runs the same app with its
  # --gpu amd backend.)
  services.fah-panel = {
    enable = true;
    gpu = "nvidia";
    nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
    # --budget 180 W flags the CPU+GPU DC estimate against this box's reality:
    # the PSU adds ~30-40 W of board/SSD/fans on top of what the panel sums,
    # the derated steady state lands ~150 W, and the brownout trips came from
    # steps toward ~230 W. Rail voltages are NOT readable here: the HP
    # Super-I/O exposes only a dead pwm1 and there is no BMC — the DC estimate
    # is the closest software proxy (a multimeter or an INA226 inline monitor
    # on the GPU adapter line is the real instrument).
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
