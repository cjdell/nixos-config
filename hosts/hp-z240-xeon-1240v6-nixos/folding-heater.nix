# hp-z240-xeon-1240v6-nixos as a folding@home space heater — CPU AND GPU,
# GPU HARD-CAPPED AT 100 W, cap applied LATE (see the power saga below).
#
# POWER HISTORY, adoption day 2026-11-14, measured with a zen3-side 3 s
# telemetry poller (survives the target dying):
#   1. Flat out (cpus=8, GPU uncapped): HARD-RESET twice, at +101 s and
#      +130 s, journals ending mid-line — once extracting FahCore_28's
#      libnvrtc .so files, once mid OpenCL/CUDA enumeration. No panic/MCE
#      = power loss, not a crash. 240 W SFF PSU brown-out, the exact
#      signature that derated the FIRST Z240 SFF (old .65, git ff7e54b^).
#   2. "Derate" (boot-time nvidia-power-limit -pl 100 + cpus=4 + delay):
#      STILL reset. The poller caught 187.1 W @ 99 % util — while
#      nvidia-smi reported power.limit = 100 W.
#   3. ROOT CAUSE, from nvidia-smi -q -d POWER on the idle box: Current /
#      Requested / Default Power Limit all back at **200 W** (unlocked OEM
#      VBIOS; min limit 100 W) even though the boot unit applied 100 W at
#      01:25:33 and exited 0 — the limit had been REVERTED to the VBIOS
#      default (persistence mode was off; the display stack re-initialises
#      the GPU after multi-user.target). So every fold had been running at
#      200 W all along, and the old box's "real 120 W cap still reset"
#      was almost certainly the same silent reversion — its caps were
#      theatre too.
#   4. FIX, verified live: `nvidia-smi -pm 1 && nvidia-smi -pl 100` applied
#      AFTER the desktop is up, immediately before folding starts. It
#      sticks: 95-101 W at 100 % util, SM clocks pinned 822-899 MHz with
#      throttle reason 0x4 (SW Power Cap) — the firmware enforcing via
#      clocks. (Clock locking proper, -lgc, is "not supported" on this
#      VBIOS, so the power cap IS the clock limiter.) Box then ran full
#      CPU+GPU load for 25+ min with no reset.
#   The cap therefore lives in fah-client's OWN ExecStartPre (mkAfter —
#   runs after the module's install-config + startDelay-sleep, so seconds
#   before ExecStart, with nothing able to revert it in between). The
#   boot-time nvidia-power-limit unit is kept for early coverage and the
#   panel's ordering, but its value alone is NOT trustworthy — do not
#   delete the ExecStartPre pair if you "simplify" the boot unit.
#   If this box ever hard-resets again: first re-verify the cap actually
#   held (`nvidia-smi --query-gpu=power.draw,power.limit,enforced.power.limit,clocks_throttle_reasons.active --format=csv`
#   while folding — expect ~100 W / 0x4), THEN drop cpus to 4, THEN blame
#   the PSU for real (the old box's notes suspect the 970's aux-power
#   connector on this platform).
#
# CPU: the Xeon E3-1240 v6 is 4 Kaby Lake cores / 8 threads with AVX2
# (80 W TDP); all 8 fold. Steady state: GPU 100 W + CPU ~70-85 W + board
# ~35 W ≈ 210-220 W — inside the 240 W rail now that the GPU cannot boost-
# step; the cap also kills the transients, which is what actually trips PSUs.
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
# wiped (the v8.5.6 DB is /var/lib/fah-client/client.db, NOT the older
# db.sql.fah) or the change made live in Web Control / fahctl.
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

let
  nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
in
{
  imports = [
    ../../common/fah-panel.nix
    ../../common/folding-at-home-native.nix
  ];

  services.folding-at-home-native = {
    enable = true;
    userName = "cjdell";
    teamNumber = 236565;
    # GPU folding stays ON — the 100 W cap enforces fine once it is applied
    # in the right ORDER (see the power history). startDelay=90 keeps the
    # fold step out of the boot race; it also guarantees the desktop (the
    # thing that reverts the cap) is fully up before we set it.
    enableGpu = true;
    cpus = 8;
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

  # THE load-bearing pair (see power history #3/#4): runs last in the
  # module's ExecStartPre chain — after fah-install-config and the 90 s
  # startDelay sleep, seconds before ExecStart — so persistence is on and
  # the 100 W cap (this VBIOS's minimum) is set with only fah itself left
  # to touch the GPU. -pm 1 is not decoration: without it nvidia-smi warns
  # and the limit's lifetime is tied to driver sessions.
  # The "+" prefix is LOAD-BEARING: the service runs as user fah and NVML
  # refuses it (status=4/NOPERMISSION crash-loop without the prefix —
  # verified 2026-11-14); "+" makes these two run as root while the
  # client itself stays unprivileged.
  systemd.services.fah-client.serviceConfig.ExecStartPre = lib.mkAfter [
    "+${nvidiaSmi} -pm 1"
    "+${nvidiaSmi} -pl 100"
  ];

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

  # Boot-time application of the same cap: early coverage (idle display
  # box, the panel's baseline) and unit ordering for the slider. Its
  # EFFECT ALONE IS NOT SUFFICIENT — the desktop stack can and did revert
  # it before fah started; the ExecStartPre pair above is what holds.
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
      ExecStart = "${nvidiaSmi} -pl 100";
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
    nvidiaSmi = config.hardware.nvidia.package.bin + "/bin/nvidia-smi";
    # --budget 180 W flags the CPU+GPU DC estimate against this box's
    # reality (old Z240 numbers: ~30-40 W of board/SSD/fans above what
    # the panel sums; the brown-out trips came from steps toward ~230 W).
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
