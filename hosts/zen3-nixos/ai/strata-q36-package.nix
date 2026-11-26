# Strata 0.2.21, Q36-ONLY build: the `strata-q36` engine (Qwen3.6-35B-A3B,
# arch qwen35moe) + its serve layer, for the 256K Qwen3.6 swap lane
# (./strata.nix `models.qwen36-256k-fp8` / `-fp4`).
#
# WHY A THIRD STRATA PACKAGE (and why 0.2.21, not "bump everything").
# The 256K question is `docs/qwen36-256k-vram.md`: UD-Q4_K_XL (21.29 GiB of
# weights) + its fp32 KV at 262,144 (11.48 GiB) + buffers is ~36 GiB against
# this R9700's 31.86, so at our engine pin 0.1.59.1 full residency at 256K
# needs a ~13-16 GiB quant.  Engine 0.1.6x removed that constraint on its own:
# the q36 path grew `--kv fp32|fp16|fp8|fp4` (upstream's own bench,
# docs/bench-results/2026-11-20-q36-kv-precision/README.md: KV at
# 262,144 = 11.56 GiB fp32 / 6.06 fp16 / 3.35 fp8 / **1.65 fp4**, KL/step
# 0.0044 / 0.0064 / 0.0115 nats, top-1 token identical to fp32 in 8/8 steps;
# fp4 is q4_0 with a 256-point Hadamard rotation, and the rotation is not
# optional).  `--native ... --max-context 262144 --kv fp8` therefore keeps the
# Q4_K_XL file we already have fully resident at 256K in ~27.4 of 31.86 GiB.
# Our pinned 0.1.59.1 has no such option: its q36 arg parser ends in
# `ignoring --kv fp8 (not an option of this engine)` - silent, and the run then
# goes hybrid (experts on CPU, ~81 vs ~180 tok/s upstream's own R9700 numbers).
#
# Same isolation as ./strata-inkling-package.nix: the MAIN lane stays pinned at
# 0.2.13.1 + engine 0.1.59.1, because our own upstream issue #6420 (the layers
# 18-22 prefill spin that killed 0.2.15/0.2.17, docs/strata-prefill-stall-2026-11-20.md)
# is still OPEN - nothing in the 0.2.18..0.2.21 notes touches that class.
# One unit, one binary, one serve: bumping the q36 lane cannot move a
# Qwen3.8-Flash-Next answer by one token.
#
# WHY THE `strata-q36` TARGET AND NOT `strata`.  cmake/strata_gpu_engine.cmake:
# links `strata_qwen35` into the qwen binary (`STRATA_HAVE_QWEN35`, "the family
# switch at the top of its main") AND builds `add_executable(strata-q36
# src/qwen35/q36_main.cpp)`, whose entire body is
# `return strata::qwen35::run(argc, argv)` - "the same entry point `strata`
# switches to for a qwen35moe model".  So the q36 lane gets the identical
# engine without compiling the Qwen3.8 engine/spec layers at all.
#
# WHAT ELSE 0.1.67 BRINGS TO THIS LANE (0.2.19 -> 0.2.21 notes, read in full
# 2026-11-25): 0.2.20's AMD HIP pass - unified Wave32 WMMA prefill (70.7 TFLOPS
# dense, 28.5-36.7 fused dequant-to-LDS) + 6-op v_perm_b32 LUT16 Wave32 DP4A
# decode (451-583 GB/s) on the Unsloth expert formats this engine reads, and
# exact heterogeneous Unsloth per-layer slot sizing (#4870 #6354); the #879
# 24K-45K long-prompt non-finite fix (#6431, the grid-overflow class we carry
# local instrumentation for); 0.2.21's "agent sessions reuse their prompt on
# every backend" (a long agent session stops re-reading its whole prompt every
# turn) and the #6776 prompt-reading accuracy fix.  0.2.17's K-quant/IQ4_XS
# loader fixes (#3925 ssm_alpha/ssm_beta, #5595 Q4_K down experts) are also in
# here - relevant because UD-Q4_K_XL is a K-quant and our pin predates them.
#
# WHAT THIS PACKAGE SKIPS vs ./strata-package.nix (0.2.13.1), deliberately:
#   * the local engine patches (strata-kernel-audit.diff, the kv_q8.cu /
#     prefill/kernels.cu int8-KV clamps, the hang-watchdog class): all of them
#     are Qwen3.8 grouped-expert/QSA files.  STRATA_KERNEL_AUDIT=1 stays set in
#     the unit env (from ./strata.nix) and is simply unread here;
#   * `-DSTRATA_PREFILL_MMQ` - the option is gone since the 0.2.16 re-layout
#     (same finding as ./strata-inkling-package.nix, port proven in c905142);
#   * `strata-vision`: `strata-q36` reads pictures IN-PROCESS (--vision +
#     mmproj, upstream measured the reader at 1,325 MiB of VRAM on a 12 GiB
#     card), so this lane runs text-only until the 256K residency numbers are
#     in - see the `vision = null` on the models entries in ./strata.nix.
#     If the 256K measurement says we want pictures back, build target
#     `strata-q36` stays and the vision block goes back to OUR strata-vision.
#   * the qwen `strata` binary and its DFlash2 drafter machinery: serve's
#     drafting.apply() skips non-Flash-Next families anyway; the q36 drafter is
#     the MTP block inside the GGUF (`--mtp 2`).
#
# RUNTIME ROCm is the same story as the other lanes (rocm10-runtime.nix via
# `lib_dirs` in ./strata.nix's run config): nixpkgs' clr is link/header-only at
# build time, and at runtime child_env() prepends the store-built ROCm 10.0.0
# libs.  Caveat carried honestly: upstream validated the fp16/fp8/fp4 KV
# kernels on CUDA only ("this file is CUDA-only in the tree, with no twin for
# either backend to build" - no HIP measurement).  It compiles for HIP because
# q36_engine.cu is a .cu the HIP build compiles, exactly like our 0.1.59.1 HIP
# build already does for the fp32 path; whether fp4 attention is FASTER on
# gfx1201 is precisely what scripts/qwen36-256k-check.sh measures.
#
# Build standalone: nix build .#strata-q36
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  makeWrapper,
  python3,
  rocmPackages,
}:

let
  # Same serve deps as ./strata-package.nix and ./strata-inkling-package.nix
  # (jinja2 + regex at module scope; pillow/psutil/numpy optional).
  serverPython = python3.withPackages (
    ps: with ps; [
      jinja2
      regex
      pillow
      psutil
      numpy
    ]
  );
in
stdenv.mkDerivation (finalAttrs: {
  pname = "strata-q36";
  version = "0.2.21";

  # v0.2.21 (2026-11-24) - the same source tree as ./strata-inkling-package.nix
  # (identical fetchFromGitHub, so one copy in the store); only the target
  # differs.  Engines/Control 0.1.67.
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "refs/tags/v0.2.21";
    hash = "sha256-AhmGZPvxkBqFGsA2CDxiaiW1CwncjOuZESJX1G2Xv0A=";
  };

  # The cmake hook cd's into build/ first, so this is relative to build/.
  cmakeDir = "../engine";

  nativeBuildInputs = [
    cmake
    pkg-config
    makeWrapper
  ];

  buildInputs = [
    rocmPackages.clr
    rocmPackages.hipblas
    rocmPackages.rocblas
    rocmPackages.hipblaslt
  ];

  cmakeFlags = [
    "-DSTRATA_ENABLE_CUDA=OFF"
    "-DSTRATA_ENABLE_HIP=ON"
    "-DSTRATA_BUILD_TESTS=OFF"
    # Native (IQ/K) expert support through the vendored ggml-cpu - ON by
    # default, named because it is what gates STRATA_Q36_CPU_POOL, the q36
    # hybrid mode's CPU expert pool.  We run for FULL residency (every expert
    # in VRAM) and want the pool compiled in as the fallback that place_experts
    # uses when a context does not fit; refusing instead would be a different
    # failure mode than the one docs/qwen36-256k-vram.md describes.
    "-DSTRATA_NATIVE_EXPERTS=ON"
    "-DCMAKE_HIP_COMPILER=${rocmPackages.clr.hipClangPath}/clang++"
    "-DCMAKE_HIP_ARCHITECTURES=gfx1201"
    "-DCMAKE_PREFIX_PATH=${
      lib.makeSearchPath "lib/cmake" [
        rocmPackages.clr
        rocmPackages.hipblas
        rocmPackages.rocblas
        rocmPackages.hipblaslt
      ]
    }"
  ];

  # ONLY strata-q36 (engine/cmake/strata_gpu_engine.cmake:579).  The default
  # buildPhase would compile the whole Qwen3.8 engine for nothing.
  buildPhase = ''
    runHook preBuild
    cmake --build . --target strata-q36 --parallel $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/strata

    q36_bin=""
    for c in src/qwen35/strata-q36 build/src/qwen35/strata-q36; do
      [ -x "$c" ] && q36_bin="$c" && break
    done
    [ -n "$q36_bin" ] || q36_bin=$(find . -type f -name strata-q36 -perm -u+x | head -1)
    [ -n "$q36_bin" ] || { echo "strata-q36 binary not found"; exit 1; }
    echo "installing $q36_bin"
    install -Dm755 "$q36_bin" $out/bin/strata-q36

    # The serve layer, from the PATCHED tree (relative to build/, not
    # ${finalAttrs.src}) - the lesson recorded in ./strata-inkling-package.nix:
    # installing the pristine copy ships unpatched serve while the C++ half is
    # compiled from the build dir.
    cp -r ../terminal/serve ../terminal/tools \
          ../terminal/data ../terminal/strata_control \
          ../terminal/strata_cli $out/share/strata/

    # The same local serve tweak as ./strata-package.nix and
    # ./strata-inkling-package.nix: prefix post-stream failures with "server
    # error" so a dead/restarted engine reads as retryable.  The single
    # _chat_failed funnel anchor is re-checked UNIQUE on v0.2.21 by the inkling
    # package's identical substituteInPlace.
    substituteInPlace $out/share/strata/serve/server.py \
      --replace-fail '            error = {"type": kind, **({"code": code} if code else {}), "message": message}' \
                     '            error = {"type": kind, **({"code": code} if code else {}), "message": message if str(message).startswith("server error") else "server error: " + str(message)}'

    makeWrapper ${serverPython}/bin/python3 $out/bin/strata-server \
      --add-flags "-m serve.server" \
      --set PYTHONPATH "$out/share/strata"
    runHook postInstall
  '';

  # No doCheck here on purpose.  The one check worth running without the GPU is
  # "does this build parse --kv": `strata-q36 --kv bogus` must print
  # "strata-q36: --kv takes fp32, fp16, fp8 or fp4 (not bogus)" (exit 2) on
  # 0.1.67, where the 0.1.59.1 pin answers "ignoring --kv bogus (not an option
  # of this engine)".  It needs the runtime ROCm on the loader path to get that
  # far - the libs come from ./rocm10-runtime.nix via lib_dirs at service
  # start - so scripts/qwen36-256k-check.sh does it as its first live step.

  meta = {
    description = "Strata 0.2.21 strata-q36 engine (Qwen3.6-35B-A3B own path, HIP/gfx1201, --kv fp16/fp8/fp4) + serve layer";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-server";
  };
})
