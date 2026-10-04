# Strata (https://github.com/Niko1221/Strata) for the R9700 (gfx1201).
#
# Strata is NOT a llama.cpp wrapper: it is its own ggml-based engine. The
# hottest MoE experts of Qwen3.8-Flash-Next stay on the GPU, all of them live
# in system RAM, cold ones are computed on the CPU, and a small MTP draft head
# "guesses" tokens the big model then verifies in one pass. That is what makes
# the ~76 GB IQ3_XXS model usable on a 32 GiB card (measured ~45-62 tok/s on
# an R9700; see upstream docs/AMD_HIP.md, "RDNA4 (gfx1201)").
#
# This builds the engine for HIP/gfx1201 and bundles the Python `serve`
# layer. Model data (GGUF, packs, MTP runtime) is NOT in the store: it is
# prepared once by hand and passed via a JSON run config (see ./strata.nix).
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
  # Upstream pins llama.cpp (for ggml + its i-quant block layouts) at this
  # exact revision; setup.py downloads the same zip. Passing it as
  # STRATA_GGML_DIR keeps the build offline and lets Nix pin it.
  llama = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
    hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
  };

  # serve/server.py needs jinja2 (chat template) and regex (tokenizer);
  # pillow (WebP image parts) and psutil (Monitor) are optional; numpy is
  # only used by the one-time pack tools, bundled for convenience.
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
  pname = "strata";
  version = "0.1.39";

  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "6f32ec070f23ced9f50e704d854d775da52591ab";
    hash = "sha256-9jqmV+AbGKiOqW1DvKjqBLVXmJCI9o6WI85QoHj5vBI=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
    makeWrapper
  ];

  # The default rocmPackages scope (all gfx targets, incl. gfx1201 in ROCm
  # 7.2.3) so those derivations hit the binary cache; our own code is
  # compiled for gfx1201 alone below.
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
    # ggml's MMQ prompt kernels (gfx1201 has them; upstream's R9700 page
    # builds with this on). Built as HIP, so no CUDA toolkit is needed.
    "-DSTRATA_PREFILL_MMQ=ON"
    "-DSTRATA_GGML_DIR=${llama}"
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

  # #606 fix is incomplete upstream (0.1.39): the commit "q8_1 activations:
  # keep the block's fp16 scale and sum finite" clamped two of the three q8_1
  # activation quantizers (iq_kernels.cu q8_1_store and native_mmvq.cu
  # native_quantize_q8_1_kernel) but missed native_swiglu_quantize_q8_1_kernel
  # in the same file. Its block's `sum` (and `d = amax / 127`) still round to
  # +inf past fp16's 65504, and the dot product then reads inf * 0 = NaN; a
  # NaN in the residual makes the model answer one token (`!`) forever -- the
  # very degeneracy the guard in serve/server.py:2319 exists to end. SwiGLU is
  # where massive activations are largest, so it is the likeliest block to
  # overflow (see upstream f8fe938, "the saturated FP16 SwiGLU product...").
  # Apply the same clamp/quantise/store helpers its sibling now uses.
  postPatch = ''
    substituteInPlace src/kernels/cuda/native_mmvq.cu \
      --replace-fail 'const float d = amax / 127.0f;' \
                     'const float d = q8_1_finite(amax / 127.0f);   // #606 (SwiGLU): keep the block scale finite' \
      --replace-fail 'const int8_t q = amax == 0.0f ? 0 : roundf(xi / d);' \
                     'const int8_t q = q8_1_quant(xi, d, amax);' \
      --replace-fail 'y[i / Q8K].ds = make_half2(d, sum);' \
                     'y[i / Q8K].ds = q8_1_ds(d, sum);'
  '';

  # Upstream has no install() rules for `strata`; install the binary and the
  # Python serve layer by hand. `strata-server` is what systemd runs
  # (`python -m serve.server`); the model pack / GGUF / MTP runtime stay
  # outside the store and are named by --config.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/strata
    install -Dm755 strata $out/bin/strata
    cp -r ${finalAttrs.src}/serve ${finalAttrs.src}/tools ${finalAttrs.src}/data $out/share/strata/
    makeWrapper ${serverPython}/bin/python3 $out/bin/strata-server \
      --add-flags "-m serve.server" \
      --set PYTHONPATH "$out/share/strata"
    runHook postInstall
  '';

  meta = {
    description = "Strata: run Qwen3.8-Flash-Next across GPU VRAM, RAM and CPU (HIP/gfx1201)";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-server";
  };
})
