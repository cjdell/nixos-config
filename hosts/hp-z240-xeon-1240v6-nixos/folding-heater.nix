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
#   5. 2026-11-15 evening: THE CAP HELD; THE CARD DIED. New failure mode,
#      NOT brown-out: the GPU falls off the PCIe bus. Signature every time:
#      AER "Physical Layer" RxErr/BadDLLP on the root port -> Uncorrectable
#      (Fatal) CmpltTO -> "Xid 79, GPU has fallen off the bus" -> secondary
#      bus reset -> "not ready ... giving up". Machine survives, card goes
#      zombie (config space garbage, current_link_speed=Unknown) until
#      reboot; console dies with it (the 970 is the only display output).
#      Evidence the card is the cause, not power, not board: the 970 could
#      not train past 2.5 GT/s (Gen1) on EITHER of the two Gen3-capable
#      ports — slot 1 = 0000:00:01.0 CPU x16, slot 2 = 0000:00:1d.0 PCH
#      x4 (full-length physical) — every boot, both PSUs, including cold
#      boots at idle; the same chipset trains its NVMe at 8GT/s x4 fine.
#      [#9 VOIDED THIS PARAGRAPH: 2.5 GT/s sampled at idle is correct
#      behaviour, and the 1060 — which passes every non-OpenMM test thrown
#      at it — does exactly the same thing. What still stands from #5 is
#      that card's own failure list, not the link claim.]
#      Time-under-fold collapsed over five crashes: hours -> 1.3h -> 3.8h
#      -> 7min -> 46s, the last one on a cold card with the cap applied
#      seconds earlier (and the 200->100 W "from 200.00 W" log lines show
#      the display stack still reverts the VBIOS default between boots, so
#      the ExecStartPre pair remains load-bearing — its +- prefixes earned
#      them again: with a dead card the client came up CPU-folding.)
#      The user swapped the PSU; it changed nothing — the PSU was never
#      this mode. NOTE: no riser in this chassis, cards plug straight into
#      the board (an earlier diagnosis here assumed a riser — wrong).
#      Resolution: 970 retired from folding (enableGpu=false, fah-provision
#      passes --no-gpus every boot), kept as console GPU until replaced.
#      Non-FAH proof same night: glmark2 + FurMark (nixpkgs `furmark` = the
#      official Geeks3D binary; needs NIXPKGS_ALLOW_UNFREE=1 + --impure)
#      rendering on the console Xwayland died the identical way — Xid 69 GL
#      class-error volley, then Xid 79 off-bus ~4.5 min in (23:03-23:05).
#      The card fails ANY real GPU work, GL or compute: the 3D pipeline
#      errors too (Xid 69), not just the PCIe PHY. Idle console (Plasma
#      compositing, ~0 % util) survives.
#      Replacement: a healthy card shows "8.0 GT/s" in the boot bandwidth
#      line (slot 1 was believed innocent here — #6 soured that confidence).
#      [#9: DO NOT USE THAT RULE. Read the link while the GPU is loaded; the
#      fault signature is a DOWNGRADE above 80 % util (gpu-probe's
#      under-load-drops), which was zero across tonight's whole suite.]
#      Prefer a slot-powered card (no aux 6-pin) to close the aux-connector
#      chapter the first Z240's notes also suspected. Then re-verify the cap
#      recipe under load before trusting it again.
#   6. 2026-11-19: two fresh USED cards + a new PSU. Now: 550 W PSU (user
#      swap; both GPU 6-pins fed via ADAPTERS/SPLITTERS — derated caps are
#      the safety net, verify power.draw stability under load), folding on
#      GTX 1060 6GB (GP106, slot 1, 01:00.0, UUID cb720fd0-…) + a SECOND
#      used GTX 970 (GM204, slot 2, 03:00.0, UUID 2275ad94-…; the dead
#      card's ad1f1525-… is gone). PCIe again: BOTH train Gen1-only. The
#      970's own LnkCap = 2.5GT/s x16 — its Gen3 PHY is fused off
#      (mining-crippled); cannot train better, and FAH does not care. The
#      1060 advertises 8GT/s x16 but falls back to Gen1 even on a manual
#      forced retrain (root-port target speed was already 3;
#      EqualizationPhase1+/Complete+, speed stays 2.5GT/s, zero AER) —
#      three cards in a row Gen1 in slot 1 now puts the slot's Gen3
#      signal path itself under suspicion. Chasing 8GT/s is pointless:
#      PCIe bandwidth is noise to FAH (the dead card ran Gen1 x16 for
#      weeks); watch Xid/AER per card instead. Quiet profile (user: LOW
#      POWER, low noise, not max points): 1060 -pl 75 (range 60–140;
#      ~90 % of its 100 W PPD, near-silent) + 970 -pl 100 (VBIOS floor);
#      GPU total 175 W. Caps per card by bus id (NOT index — indices shift
#      when a card is skipped), enforced in fah-client ExecStartPre as ever.
#   7. 2026-11-19, one hour later: THE SECOND 970 IS SCRAP TOO — quieter
#      death than #5. No Xid, no fatal AER (11 correctables on its port,
#      then flat): its FahCore_28 burned 99 % CPU for 20+ min with ZERO
#      steps — the CUDA engine never executes a task — and the hung NVML
#      ioctl jammed nvidia-smi box-wide (panel included). The 1060 folded
#      on throughout (Gen3 x16 confirmed — see below). Console lives on
#      the 1060's HDMI (card1-HDMI-A-1 connected; every 970 output
#      disconnected), so the 970 has NO remaining role: pull it.
#      Slot-1 vindication: the boot-time Gen1 curse is a cold-boot
#      negotiation quirk — forcing a retrain (setpci CAP_EXP+0x10.w |=0x20
#      on the root port, target speed already 3) locked 8.0GT/s x16. A
#      Gen1 boot line no longer implies a sick card.
#      Gotcha (new, cost a reboot): unbinding a GPU whose CORE is hung
#      inside a driver ioctl leaves that core in D state — SIGKILL-proof —
#      which wedges fah-client's stop job (systemd can neither stop nor
#      leave it; a reboot is the only reclaim). Unbind only works as a
#      BOOT-TIME exclusion, before anything opens the device — hence the
#      hide-sick-970 oneshot below, and never `unbind` as a live remedy on
#      this platform again.
#   FINAL fleet (this boot onward): GTX 1060 6GB @ 75 W + 8 CPU threads.
#   When the 970 is physically removed, delete the hide-sick-970 unit and
#   the `-i 00000000:03:00.0` cap line.
#   8. 2026-11-19 02:19: THE 1060 DIED TOO — ONCE. While the user moved
#      the fah-panel cap slider: RxErr → fatal CmpltTO → Xid 79 on
#      00:01.0, same fall-off signature as #5. But on reboot it came back
#      PERFECT: Gen3 x16, folding 93 % @ 66.7 W under the 75 W cap, NVML
#      clean, zero AER since. A card whose silicon is going stays down;
#      this one flashed, tripped and re-armed — which points the finger
#      at its 12 V feed: both Xid-79 deaths of this saga (#5's 970 five
#      times, this one once) happened on cards powered VIA ADAPTERS/
#      SPLITTERS (user-confirmed wiring, 550 W PSU). A -pl write pokes
#      the PMIC over a sideband and the card's power sequencing is at
#      its most vulnerable exactly then — with a marginal adapter
#      terminal that is a trip. RULES from this: (a) no live slider
#      writes on this box — caps are boot-time business via the
#      ExecStartPre pair, the panel's read-only telemetry is fine;
#      (b) rewire the 6-pins to native PSU cables (or a native
#      8-pin->2x 6-pin) before believing any more GPU verdicts here —
#      the aux-connector suspicion the FIRST Z240's notes left behind
#      (#1, "suspect the 970's aux-power connector") may be the real
#      headline of this whole platform saga. Console incident (02:34,
#      self-inflicted — recorded so nobody repeats it): the 02:19 fall did
#      NOT kill the desktop. kwin kept running the whole time; "kwin gone"
#      was a false negative from `pgrep -x kwin_wayland` — Nix exec-names
#      it `.kwin_wayland-w` in comm, so -x NEVER matches; use
#      `pgrep -f kwin_wayland`. Acting on that false read, `systemctl
#      restart display-manager` spawned a SECOND seat session whose kwin
#      then fought the survivor for DRM master: "Failed to find a working
#      output layer configuration: EACCESS", ~20 SIGABRT cores, a drkonqi
#      processor tail queuing for minutes, /var/lib/systemd/coredump at
#      2.5 G (incl. 5 days of uncleaned baloo/FahCore history). Correct
#      repair, verified: `loginctl terminate-session <dup-id>` — the
#      survivor keeps master, console never blinks. NEVER restart
#      display-manager over a console you have not PROVEN dead.
#      Post-revival bake (02:45-03:31, 45 min, /tmp/opencode/bake-watch2):
#      PASSED — 93-99 % util, WU 15 %->35 %, temp steady 59-61 C,
#      power.draw 57-77 W under the 75 W cap never exceeded, +0 AER on
#      its port, 0 Xid. Verdict: the 02:19 fall was a one-time power-
#      sequencing trip, not a card beginning to die — which keeps the
#      adapter-fed 6-pin squarely prime suspect and rule (a) absolute:
#      any future -pl write waits until the wiring is native.
#   9. 2026-11-20/21, with scripts/gpu-probe: THE FAULT NOW REPRODUCES ON
#      DEMAND, AND IT IS NOT THE CARD, NOT THE LINK, NOT POWER, NOT RAM.
#      (a) THE 1060 PASSES EVERYTHING THAT IS NOT OPENMM. 12 traditional
#      stress steps at a verified-held 120 W cap: glmark2 720p+1080p
#      (108 W), memtest_vulkan ~7.5 min pinned at the cap (avg 113.6 W,
#      peak 125.7 W, ~2.9 TB of VERIFIED traffic at 150 GB/s, 0 errors),
#      clpeak (120 W), hashcat -b (~40 kernel types, 123.6 W), stress-ng
#      --cpu-method all, stress-ng --vm, memtester, sysbench, 8-CPU+VRAM
#      combined — and clpeak again at the end, healthy before AND after.
#      Zero Xid, zero AER across the GPU half. Plus 34 cold CUDA bring-ups
#      (7 from a genuinely parked 2.5 GT/s link): 288-336 ms each, no fault.
#      (b) #5's AND #6's CENTRAL EVIDENCE IS VOID — it was a sampling
#      artifact of my own tool. A link that reads 2.5 GT/s while the GPU is
#      IDLE and climbs to 8.0 the instant work arrives is CORRECT behaviour
#      (hardware autonomous speed setting); the healthy 1060 does exactly
#      that, and the root port sits at LnkSta 8.0GT/s x4 Target 8.0
#      EqualizationComplete+. So "could not train past Gen1 on either slot"
#      and "a healthy card shows 8.0 GT/s in the boot bandwidth line" prove
#      nothing. The metric that does mean something is a link DOWNGRADE
#      while utilization > 80 % — gpu-probe emits it as under-load-drops,
#      and it was ZERO in every step, including the 125 W soak. Likewise
#      Xid 79 + AER is a consequence pattern, not proof of dead silicon:
#      it fired tonight on a card that passed everything else.
#      (c) THE REPRO (gpu-probe-fahcore-repro): FahCore_28 (OpenMM 8.3.1)
#      on a real GPU WU, run under fah-client's OWN Environment/User/
#      sandbox with the client stopped, the WU copied to /run (never the
#      original), 8 CPU threads of load alongside. From scratch it reaches
#      "Running tests / All tests passed / Checkpoint completed at step 0"
#      — so real CUDA kernels executed and verified — and 20 s after the
#      core starts the card is off the bus: correctable-only AER on 00:1d.0
#      then Xid 79 + 154. The WU was R1ttHC75 (the one that folded 1 125 000
#      steps in production before the 02:24 fall) and the "poison" WU
#      J0glvr behaves identically, so THE WORK UNIT IS NOT THE VARIABLE.
#      (d) #7's "scrap" 970 symptom REPRODUCED on a card proven healthy:
#      with the card gone, FahCore_28 sat at 97 % CPU, R state, zero steps,
#      and ignored SIGTERM. "Core spins, no steps" is therefore a property
#      of this core+driver path, not of sick Maxwell silicon. Both 970s are
#      out of the box, so "they were fine too" stays inference, not fact —
#      run steps/traditional.tsv on one before buying another card.
#      (e) THREE REPRO GOTCHAS that each produced a placebo run: `-lifeline
#      1` makes the core hard-exit unwritten (a service user cannot signal
#      PID 1 — EPERM reads as "client died"); the scratch dir must NOT be
#      under /tmp or /var/tmp because the launched unit inherits
#      PrivateTmp=yes and systemd dies with status=200/CHDIR, which looks
#      exactly like FAH's own exit 200 "results ready"; and FahCore_28's
#      RPATH is the dead conda path /opt/conda/envs/build/lib, so it NEEDs
#      libOpenMMCPU.so by plain soname — the client puts the core dir on the
#      child's LD_LIBRARY_PATH and you must too, or the core dies in the
#      loader with 127 and never touches the GPU.
#      (f) NEXT: steps/corebisect.tsv — same WU, one knob per step across
#      reboots (CUDA_MODULE_LOADING=EAGER, CUDA_LAUNCH_BLOCKING=1, core 27
#      = OpenMM 8.2.1, OpenCL instead of CUDA, no CPU load, and resume-from-
#      checkpoint as the shape that ran 4.4 h). Step 1 is a positive control
#      that MUST kill the card; read it before believing any PASS. The
#      12 V adapter wiring from #8 is still unproven and still suspect: the
#      operating point of tonight's kill is UNKNOWN (the 2 s power/util CSV
#      was added to the repro right after it, and /run ate the evidence),
#      while production's was caught at 29 W and 1 % util — so "it is only a
#      heavy transient" is untested here, not disproved. The bisect runs
#      with telemetry now, and so does the answer.
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
    # GPU folding BACK ON 2026-11-19 (power history #6): two fresh used
    # cards — GTX 1060 6GB (slot 1) + a second GTX 970 (slot 2) — fold at
    # quiet caps 75 W / 100 W via the ExecStartPre pair below. fah-provision
    # passes neither --no-gpus now, so detected GPUs are enabled every boot.
    # startDelay=90 keeps the fold start out of the boot race and guarantees
    # the desktop (the thing that reverts caps) is up before we set them.
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
  # The "-" prefix is ALSO load-bearing (learned the same afternoon, 12:56:
  # Xid 79 GPU-fallen-off-the-bus while the pause window had the client
  # stopped): nvidia-smi then exits 6/NOTCONFIGURED, and without "-" a dead
  # GPU failed ExecStartPre and crash-looped the WHOLE client — not even the
  # CPU folded, 4 h dead. A GPU cap may never gate folding; on a dead card
  # these lines now fail silently and the client comes up CPU-only (its own
  # GPU probe finds nothing and simply skips the slot).
  # Per-card caps 2026-11-19 (history #6): bus-id `-i` (not index — indices
  # shift when a card is skipped), 1060 @ 75 W (min 60, max 140; ~90 % of its
  # 100 W PPD, near-silent fan) + 970 @ 100 W (its VBIOS floor; max 200).
  # 550 W PSU but the user wants LOW POWER (quiet), and both 6-pins arrive
  # via adapters/splitters — so the caps are the load-bearing safety net,
  # verified via power.draw + clocks_throttle_reasons after the switch.
  systemd.services.fah-client.serviceConfig.ExecStartPre = lib.mkAfter [
    "+-${nvidiaSmi} -pm 1"
    "+-${nvidiaSmi} -i 00000000:01:00.0 -pl 75"
    "+-${nvidiaSmi} -i 00000000:03:00.0 -pl 100"
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
  # StartLimit* so a DEAD GPU (Xid 79) cannot make this retry forever:
  # RestartSec 5 s never trips the default 10 s burst window, and after
  # the 12:56 fall-off this unit would have spun all boot. Failing here
  # is fine — the fah ExecStartPre pair is the enforcement.
  systemd.services.nvidia-power-limit = {
    description = "Cap GTX 970 power at 100 W (nvidia-smi -pl)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "fah-client.service" ];
    unitConfig = {
      StartLimitIntervalSec = "15min";
      StartLimitBurst = "12";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # The modules appear asynchronously; retry until NVML answers.
      Restart = "on-failure";
      RestartSec = "5s";
      ExecStart = "${nvidiaSmi} -pl 100";
    };
  };

  # History #7: the slot-2 GM204 (the 970 #2) is compute-dead — a hung CUDA
  # engine that jams NVML box-wide the first time anything opens it for
  # work. Unbind it from the NVIDIA driver at BOOT, before fah, nvidia-smi
  # or the panel can open the device — an unbind while a core is hung
  # inside a driver ioctl leaves that core in SIGKILL-proof D state (the
  # live-recovery mistake, 01:39). Exits 0 when the card is absent, so it
  # is harmless until physically removed — DELETE THIS UNIT when the 970
  # is pulled.
  systemd.services.hide-sick-970 = {
    description = "Keep the compute-dead slot-2 GM204 off the NVIDIA driver (folding-heater.nix #7)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "nvidia-power-limit.service" "fah-client.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -e /sys/bus/pci/devices/0000:03:00.0 ]; then exit 0; fi
      for _ in $(seq 1 30); do
        if [ -e /sys/bus/pci/drivers/nvidia/0000:03:00.0 ]; then
          echo 0000:03:00.0 > /sys/bus/pci/drivers/nvidia/unbind && exit 0
        fi
        sleep 1
      done
      exit 0
    '';
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
    # --budget flags the CPU+GPU DC estimate against this box's reality.
    # 300 W as of #6: quiet profile 75+100 W GPU + ~70-85 CPU + ~30-40
    # board — an intentional duty target under the 550 W PSU, NOT a
    # brown-out limit (that era is history; see #1–#5).
    budget = 300;
    # Same persistence lesson as the power cap, CPU side: the panel's
    # slider is live-only (sysfs scaling_max_freq), so without a startup
    # target every reboot lets the Xeon run back into its Tjmax ~100 °C
    # pinned. 80 °C matches zen1's convention — the panel holds Tctl there
    # via the cpufreq ceiling (≈ 3 GHz on this part) and re-applies it
    # every service start; a slider move overrides live but is NOT kept
    # across restarts/boot until changed HERE.
    cpuTempTarget = 80;
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
