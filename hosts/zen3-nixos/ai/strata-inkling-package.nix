# Strata 0.2.21, INKLING-ONLY build: the `strata-inkling` shape engine + its
# serve layer, for the Inkling-2-Mini swap lane (./inkling.nix).
#
# WHY A SECOND STRATA PACKAGE (and why 0.2.21, not "bump everything").
# Inkling 2 Mini support landed in Strata 0.2.19 (2026-11-22) as its own shape
# engine, `strata-inkling` (engine/src/inkling2, component `inkling2`, CMake
# target ON by default), with a dedicated HIP backend for RDNA4
# (src/inkling2/hip, gfx1200/gfx1201 in its arch list). 0.2.21 (2026-11-24) is
# the first release that combines it with the Inkling long-context +
# small-card fixes and per-turn prompt reuse ("RTX 4090 after a 32K prompt:
# 92 instead of 29 tok/s"; HF discussion "8tk/s on 9070xt" answered
# "Fixing this!"), and it is what upstream's own R9700 figure (99-106 t/s
# decode, 3,982 t/s prefill, SQ-10) was measured with.
#
# The MAIN lane (strata.service, Qwen3.8-Flash-Next) stays pinned at
# 0.2.13.1+engine 0.1.59.1, because our own upstream issue #6420 (the layers
# 18-22 prefill spin that killed 0.2.15/0.2.17; docs/strata-prefill-stall-2026-11-20.md)
# is still OPEN and unanswered as of 2026-11-24. The engine families share
# only the Python serve layer, so running THIS tree's serve + strata-inkling
# next to the 0.2.13.1 strata engine isolates the bump to the one lane - same
# shape as the old llama.cpp inkling lane (own unit, own port, swap-table
# participant), and the same reason the 0.2.16 tree restructure makes this a
# cheap experiment: `strata-inkling` compiles from the engine/ subtree with
# the exact flags that build the qwen engine.
#
# WHAT THIS PACKAGE SKIPS vs strata-package.nix (0.2.13.1):
#   * the `strata` qwen-engine binary - buildPhase builds ONLY the
#     `strata-inkling` target (no llama fetch either: tools/vision stays
#     unbuilt, because strata-inkling reads images IN-PROCESS from
#     Inkling-2-Mini-Vision.strata, not via the strata-vision helper);
#   * strata-kernel-audit.diff (audits the qwen grouped-expert kernels only);
#   * the kv_q8.cu / prefill/kernels.cu int8-KV clamps (qwen-engine files;
#     inkling's KV is fp16/fp8, and those paths are not in the strata-inkling
#     target);
#   * -DSTRATA_PREFILL_MMQ (gone from the engine since the 0.2.16 re-layout -
#     see the port that proved this build shape in git: c905142).
#
# RUNTIME ROCm is the same story as the main lane (rocm10-runtime.nix via
# lib_dirs in ./inkling.nix's run config): nixpkgs' clr is link/header-only
# at build time; at runtime child_env() prepends the ROCm 10.0.0 libs. The
# 9070 XT community bench inside this very tree
# (docs/bench-results/2026-11-22-community-rx-9070-xt/) ran strata-inkling
# 0.1.66 happily on gfx1201 Linux.
#
# Build standalone: nix build .#strata-inkling
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
  # serve/server.py imports jinja2 + regex at module scope and treats
  # pillow/psutil/numpy as optional; verified by an AST scan of every module
  # serve reaches in 0.2.21 - serve/server_parts/anthropic_api.py and the
  # whole inkling_kind/inkling_family/inkling_fit chain are stdlib-only
  # (`anthropic`, `zstandard`, `rich`, `textual` appear only in function
  # bodies or Terminal-only files). Same set as ./strata-package.nix.
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
  pname = "strata-inkling";
  version = "0.2.21";

  # v0.2.21 (2026-11-24, tag d46f5f26) - app/Terminal 0.2.21, ALL shape
  # engines (strata-engine / strata-inkling / strata-hy4) 0.1.67. Only the
  # strata-inkling binary is installed here (see the header).
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "refs/tags/v0.2.21";
    hash = "sha256-AhmGZPvxkBqFGsA2CDxiaiW1CwncjOuZESJX1G2Xv0A=";
  };

  # 0.2.16 moved the tree into engine/ app/ terminal/ tools/; the cmake hook
  # cd's into build/ first, so the path is relative to build/ (port proven on
  # 0.2.17 in git: c905142).
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
    # Only the inkling shape engine is wanted (both default ON; naming them
    # keeps the intent legible and the qwen-engine compile off the critical
    # path - the binary itself is never installed).
    "-DSTRATA_BUILD_INKLING=ON"
    "-DSTRATA_BUILD_INKLING2=ON"
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

  # Build ONLY strata-inkling (add_subdirectory(src/inkling2) -> target in
  # src/inkling2/). The default buildPhase would compile the whole qwen
  # engine first for nothing.
  buildPhase = ''
    runHook preBuild
    cmake --build . --target strata-inkling --parallel $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/strata

    ink_bin=src/inkling2/strata-inkling
    [ -x "$ink_bin" ] || ink_bin=build/src/inkling2/strata-inkling
    [ -x "$ink_bin" ] || { echo "strata-inkling binary not found"; exit 1; }
    install -Dm755 "$ink_bin" $out/bin/strata-inkling

    # The serve layer (python -m serve.server) imports the Terminal's
    # strata_control + strata_cli at module scope; tools/ holds
    # inkling_tokenizer.py (reachable via server.py's sys.path insert of
    # ROOT/tools; ./inkling.nix's tokenizer oneshot uses it too).
    cp -r ${finalAttrs.src}/terminal/serve ${finalAttrs.src}/terminal/tools \
          ${finalAttrs.src}/terminal/data ${finalAttrs.src}/terminal/strata_control \
          ${finalAttrs.src}/terminal/strata_cli $out/share/strata/

    # Pi's agent-level retry classifies from the error TEXT; prefix
    # post-stream failures with "server error" so a dead/restarted engine
    # reads as retryable (same local tweak as ./strata-package.nix; the
    # single _chat_failed funnel anchor re-checked UNIQUE on v0.2.21).
    substituteInPlace $out/share/strata/serve/server.py \
      --replace-fail '            error = {"type": kind, **({"code": code} if code else {}), "message": message}' \
                     '            error = {"type": kind, **({"code": code} if code else {}), "message": message if str(message).startswith("server error") else "server error: " + str(message)}'

    makeWrapper ${serverPython}/bin/python3 $out/bin/strata-server \
      --add-flags "-m serve.server" \
      --set PYTHONPATH "$out/share/strata"
    runHook postInstall
  '';

  meta = {
    description = "Strata 0.2.21 strata-inkling shape engine (Inkling-2-Mini, HIP/gfx1201) + serve layer";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-server";
  };
})
