{
  lib,
  stdenvNoCC,
  bash,
  python3,
  ocl-icd,
  pciutils,
  stress-ng,
  hashcat,
  makeWrapper,
  withTraditional ? false,
  glmark2 ? null,
  vulkan-tools ? null,
  memtest_vulkan ? null,
  clpeak ? null,
  stressapptest ? null,
  memtester ? null,
  sysbench ? null,
  y-cruncher ? null,
}:
# Selective GPU stress ladder (see ./README.md). Nothing here needs a CUDA
# toolkit: the compute kernels are hand-written PTX that the *driver* JIT'es, and
# the OpenCL programs are compiled at runtime by the vendor ICD — which is what
# makes this usable on a locked-down host with no compiler and no CUDA.
#
# withTraditional=true additionally puts the *industry-standard* stress tools on
# the ladder's PATH (steps/traditional.tsv). It has to be the ladder's own PATH,
# not the caller's, because the ladder outlives the shell that armed it: it is a
# user unit that resumes after the reboots it triggers itself. The core package
# stays lean so every host can carry it.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "gpu-probe" + lib.optionalString withTraditional "-traditional";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  tradTools = lib.filter (p: p != null) [
    glmark2
    vulkan-tools
    memtest_vulkan
    clpeak
    stressapptest
    memtester
    sysbench
    y-cruncher
  ];

  # NixOS exposes the GPU vendor driver (libcuda, libGL, the vendor OpenCL ICD)
  # under /run/opengl-driver, so adding it to LD_LIBRARY_PATH is enough to reach
  # the driver on any host, NVIDIA or AMD.
  #
  # $out/bin goes on PATH as well, and that is not a courtesy: the step tables call
  # the bundle's own tools by name (gpu-probe-envtest, gpu-probe-fahcore-repro), the
  # ladder resolves `requires` with command -v, and the ladder is a user unit that
  # resumes after the reboots it triggers itself. Inheriting the arming shell's PATH
  # worked — until a campaign was armed from a shell that happened to have it — and a
  # step that silently cannot find its tool is a SKIP, not a result.
  envArgs = lib.concatStringsSep " " [
    "--prefix LD_LIBRARY_PATH : /run/opengl-driver/lib"
    "--prefix LD_LIBRARY_PATH : ${ocl-icd}/lib"
    "--prefix PATH : ${
      lib.makeBinPath (
        [
          python3
          pciutils
          stress-ng
          hashcat
          bash
        ]
        ++ finalAttrs.tradTools
      )
    }"
    # literal $out/bin, not interpolated: makeWrapper expands it at build time
    "--prefix PATH : $out/bin"
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/gpu-probe/steps $out/bin
    cp probe.py ladder.sh arm.sh envtest.sh fahcore-repro.sh $out/share/gpu-probe/
    chmod +x $out/share/gpu-probe/ladder.sh $out/share/gpu-probe/arm.sh \
      $out/share/gpu-probe/envtest.sh $out/share/gpu-probe/fahcore-repro.sh
    cp steps/*.tsv $out/share/gpu-probe/steps/

    # gpu-probe            -> one workload axis, by hand (probe.py)
    # gpu-probe-ladder     -> the per-boot state machine over a step table
    # gpu-probe-arm        -> install/tear down the user unit that crosses reboots
    # gpu-probe-envtest    -> run a probe mode inside another unit's environment
    # gpu-probe-fahcore-repro -> re-run a saved FAH work unit in that same environment
    makeWrapper ${python3.interpreter} $out/bin/gpu-probe \
      --add-flags "$out/share/gpu-probe/probe.py" \
      ${finalAttrs.envArgs}

    makeWrapper ${bash}/bin/bash $out/bin/gpu-probe-ladder \
      --add-flags "$out/share/gpu-probe/ladder.sh" \
      --set GPU_PROBE_LADDER "$out/bin/gpu-probe-ladder" \
      ${finalAttrs.envArgs}

    makeWrapper ${bash}/bin/bash $out/bin/gpu-probe-arm \
      --add-flags "$out/share/gpu-probe/arm.sh" \
      --set GPU_PROBE_LADDER "$out/bin/gpu-probe-ladder" \
      ${finalAttrs.envArgs}

    makeWrapper ${bash}/bin/bash $out/bin/gpu-probe-envtest \
      --add-flags "$out/share/gpu-probe/envtest.sh" \
      --set GPU_PROBE_HOME "$out/share/gpu-probe" \
      ${finalAttrs.envArgs}

    # PATH must contain $out/bin itself: the repro driver calls gpu-probe-envtest, and
    # envArgs already puts $out/bin on every wrapper's PATH.
    makeWrapper ${bash}/bin/bash $out/bin/gpu-probe-fahcore-repro \
      --add-flags "$out/share/gpu-probe/fahcore-repro.sh" \
      --set GPU_PROBE_HOME "$out/share/gpu-probe" \
      ${finalAttrs.envArgs}

    runHook postInstall
  '';

  meta = {
    description = "Selective GPU stress ladder for hunting flaky GPUs and PCIe links";
    mainProgram = "gpu-probe";
  };
})
