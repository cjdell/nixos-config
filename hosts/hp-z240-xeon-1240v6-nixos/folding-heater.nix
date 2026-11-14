# hp-z240-xeon-1240v6-nixos as a folding@home space heater — CPU FOLDS, GPU
# FOLDING DISABLED (2026-11-14: GPU power is electrically unsafe on this
# chassis until its PSU/aux-power path is serviced — see below).
#
# ⚠️ FLAT-OUT WAS TRIED AND MEASURED DEAD, here, 2026-11-14 (adoption day):
# the installed system booted 00:52:15 with cpus=8 + the GPU slot uncapped and
# HARD-RESET TWICE, at +101 s and +130 s — both journals end mid-line with no
# shutdown sequence, no panic, no MCE, once while extracting FahCore_28's
# libnvrtc .so files and once mid OpenCL/CUDA platform enumeration (the exact
# spin-up load step). Old box, new box, same failure (+90..121 s at boot
# spin-up), same 240 W SFF PSU.
#
# ⚠️ THE DERATE THEN MEASURED DEAD TOO, same hour: with the 100 W cap applied
# (nvidia-smi reported power.limit = 100.00 W) and cpus=4 + startDelay 90,
# a remote 3 s telemetry poller caught the card at **187.1 W, 99 % util**
# and the box was gone 3 seconds later. So -pl is NOT enforced on this
# card/VBIOS — it reports the cap and ignores it, exactly the pattern the
# old box hinted at ("at a REAL 120 W cap ... still hard-reset"). Conclusion
# for the fleet: on these Z240 SFF boxes the 970's aux-power path cannot be
# software-capped; GPU folding needs a hardware fix first (reseat/replace
# the GPU aux power connector — the old box's notes suspected a sagging
# SATA->PCIe adapter on this platform — or a <=75 W slot-powered card).
# Until then this box folds CPU-only, which sits ~120-150 W total and is
# well inside the rail.
#
# CPU: the Xeon E3-1240 v6 is 4 Kaby Lake cores / 8 threads with AVX2
# (80 W TDP); all 8 threads fold in the CPU-only mode chosen above.
#
# GPU: the GeForce GTX 970 (GM204/Maxwell, CC 5.2) would fold through the
# NVIDIA driver's own OpenCL ICD — the same ocl-icd mechanism the AMD
# heaters use, just with the vendor ICD instead of the ROCm/Rusticl one —
# and the wiring is VERIFIED working (the client enumerated the card and
# started FahCore_27/28 on "Platform: CUDA, Compute 5.2"). It is held back
# purely by the power evidence above: enableGpu = false below makes the
# configure oneshot send an explicit EMPTY GPU list, and the ICD
# environment overrides stay in place (harmless, and one flag away from a
# retry once the power hardware is fixed):
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
    # CPU-only since 2026-11-14 (header): all 8 threads fold — without the
    # GPU slot the whole box sits ~120-150 W, inside the rail's proven
    # envelope. startDelay=90 kept as cheap insurance for the boot step;
    # gpuUsage is inert on v8.5.6 (see the module note) but harmless.
    enableGpu = false;
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

  # Hardware power cap for the GTX 970 — kept as insurance, but on THIS
  # card it is NOT actually enforced: nvidia-smi reports power.limit=100 W
  # while folding measures 187 W at 99 % util (see header; the old box's
  # "real 120 W cap still reset" note was the same story). Keep it anyway:
  # harmless, the panel slider builds on it, and if a VBIOS/driver ever
  # enforces it the ceiling becomes real with zero config change.
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
