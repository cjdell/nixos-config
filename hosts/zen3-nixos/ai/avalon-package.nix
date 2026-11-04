{
  lib,
  pkgs,
  avalonSrc,
  gpuTarget ? "gfx1201",
}:

# Avalon's llama-server (https://github.com/freriadoc/Avalon) as a Nix package.
#
# Avalon is a fork of llama.cpp tuned for ONE model - Qwen3.8-Flash-Next
# (512-expert MoE) - with the experts hosted in system RAM and a GPU expert
# cache fed over PCIe, MTP speculative decoding from a shared draft head, and
# fused RDNA kernels. Its README claims 86.6 t/s on an R9700 (gfx1201,
# user-reported) where Strata measured 31 on the same machine; the box's own
# Strata sits at 60-64 tok/s on the UD-IQ4_XS pack, so the promise is mostly
# at long context and in prefill (~1,500-1,900 t/s vs our ~1,250).
#
# The fork keeps llama.cpp's .devops/nix/ tree unchanged, so this consumes it
# exactly the way upstream's flake builds its `rocm` package -
# pkgs.callPackage of .devops/nix/scope.nix, useRocm - with three deviations:
#
#   * useRocm = true is forced here instead of coming from a second nixpkgs
#     instance configured with rocmSupport (flake-parts pkgsRocm): one
#     instance, one set of rocmPackages, the same pinned ROCm 7.2.3 the rest
#     of the system uses. package.nix reads it only as a default
#     (`useRocm ? config.rocmSupport`), so overriding the arg is the supported
#     path.
#   * rocmGpuTargets = "gfx1201" - the default builds the kernel set for every
#     arch in rocmPackages.clr.gpuTargets; we have exactly one compute GPU
#     (the R9700; the RX 580 console is gfx803 and never gets work). ROCm
#     7.2.3 supports gfx1201 (it is in clr.gpuTargets, and the rocblas/hipblas
#     Tensile kernels cover it). Upstream builds/tests Avalon on ROCm 7.2.4 -
#     same 7.2 series. The installer's compiler dance (CMAKE_C(_XX)_COMPILER =
#     /opt/rocm/bin/amdclang) is NOT needed: package.nix wires the HIP path
#     the nixpkgs way, CMAKE_HIP_COMPILER = rocmPackages.llvm.clang plus
#     ROCM_PATH/HIP_DEVICE_LIB_PATH env, like nixpkgs' own llama-cpp ROCm
#     flavour.
#   * LLAMA_BUILD_TESTS=OFF - the same reason this repo wraps llamaCppPkgs
#     that way in flake.nix: package.nix never passes the flag, cmake defaults
#     it ON, and parallel test compilation ICEs GCC on test-jinja.cpp. The
#     tests are useless for a server deployment anyway.
#
# Runtime ROCm note: Strata needed the store-built ROCm 10 runtime
# (./rocm10-runtime.nix) because nixpkgs' 7.2.3 reproduces its #879
# poisoned-context class. That is a Strata-kernel bug, not a library
# requirement; Avalon links plain nixpkgs ROCm. If an Avalon run ever shows
# the same non-finite-logit symptoms, LD_LIBRARY_PATH=rocm10/lib is the known
# lever (see docs/strata-degeneration.md).
#
# The package's binary is `bin/llama-server` - a stock llama.cpp server
# surface (OpenAI-compatible /v1/chat/completions on --host/--port, /health,
# /slots, --log-prompts-dir) plus the fork's model support (IQ3_K/IQ3_KS
# types, MTP draft head, --fit placement, the moe-cache-ranking.bin preload).
# The service using it lives in ./avalon.nix; run flags and the model files
# are theirs, kept here build-only so `nix build .#avalon` works standalone.

let
  scope = pkgs.callPackage (avalonSrc + "/.devops/nix/scope.nix") { };

  rocm = scope.llama-cpp.override {
    useRocm = true;
    rocmGpuTargets = gpuTarget;
  };
in
rocm.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DLLAMA_BUILD_TESTS=OFF"
  ];
})
