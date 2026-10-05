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

  # Local HIP port of the upstream #879 finiteness instrumentation + guard
  # (gist 66419118nnn/7c9399d982d98229c61fcefaaa0b9215, on top of our exact pin
  # 6f32ec070f23ced9f50e704d854d775da52591ab).  #879 proved the repeated-token
  # degeneration is NOT the fp16-overflow class the postPatch clamps below fix:
  # the first poisoned value is garbage 0x7FFFFFFF bits written into a
  # routed-expert output row (a data-path defect in native_expert_grouped).  This
  # patch does two things:
  #   * a finiteness GUARD (on by default; STRATA_NAN_GUARD=0 disables) in
  #     Verifier::run/record_window that FAILS the window with
  #     "verify: non-finite logits" instead of emitting the degenerate token;
  #   * opt-in per-stage audit kernels (STRATA_KERNEL_AUDIT=1, set in ./strata.nix)
  #     that dump the first non-finite (layer, row, col, raw bits) at each of the
  #     four grouped-expert stages, plus the attention/shared/routed/GPU-hit/CPU-miss
  #     rows.  HIP-safe: pure cuda* shims + <<<>>> the tree already builds.
  patches = [ ./strata-nan-guard.diff ];

  # Activation quantizers must keep their fp16 scale and sum finite. Upstream's
  # #606 fix ("q8_1 activations: keep the block's fp16 scale and sum finite",
  # 0.1.39) clamped only two of the q8_1 activation quantizers (iq_kernels.cu
  # q8_1_store and native_mmvq.cu native_quantize_q8_1_kernel). In every
  # remaining case a value past fp16's 65504 rounds to +inf, the dequantised
  # dot product then reads inf * 0 = NaN, and a NaN in the residual makes the
  # model answer one token forever -- the degeneracy the guard in
  # serve/server.py:2319 exists to end (upstream #606; ggml-org/llama.cpp#23606
  # is the same defect). Clamp each one to the largest finite half with the
  # same q8_1_finite/q8_1_quant/q8_1_ds helpers the fixed siblings use (or this
  # file's hf_sat). A block that was finite before is stored bit for bit as
  # before -- values in (65504, 65520) round to 65504 anyway, and a finite
  # block's |x / d| is at most 127 -- and a NaN stays NaN, so STRATA_DBG_NAN
  # still finds it.
  postPatch = ''
    # (1) the decode fused-SwiGLU expert quantizer, missed upstream.
    substituteInPlace src/kernels/cuda/native_mmvq.cu \
      --replace-fail 'const float d = amax / 127.0f;' \
                     'const float d = q8_1_finite(amax / 127.0f);   // #606 (SwiGLU): keep the block scale finite' \
      --replace-fail 'const int8_t q = amax == 0.0f ? 0 : roundf(xi / d);' \
                     'const int8_t q = q8_1_quant(xi, d, amax);' \
      --replace-fail 'y[i / Q8K].ds = make_half2(d, sum);' \
                     'y[i / Q8K].ds = q8_1_ds(d, sum);'

    # (2) the same block store in the fused gate/up kernel (mode 7). Its launch
    # is gfx906-only today, so it is latent for the R9700's gfx1201 build, but a
    # gfx906 build would otherwise reintroduce the NaN.
    substituteInPlace src/kernels/cuda/iq_kernels.cu \
      --replace-fail 'const float d = amax / 127.0f;' \
                     'const float d = q8_1_finite(amax / 127.0f);' \
      --replace-fail 'const int8_t q = amax == 0.0f ? 0 : roundf(xi / d);' \
                     'const int8_t q = q8_1_quant(xi, d, amax);' \
      --replace-fail 'if (lane == 0) y->ds = make_half2(d, sum);' \
                     'if (lane == 0) y->ds = q8_1_ds(d, sum);'

    # (3) the int8 KV cache block scale (--kv int8): a 64-value group's
    # amax / 127 is stored fp16, so it saturates to inf past amax = 8.3M and the
    # gather's q * inf = NaN poisons attention for every later token. Decode
    # append here; the prompt append is in prefill/kernels.cu (patched below).
    substituteInPlace src/kernels/cuda/kv_q8.cu \
      --replace-fail 'const uint16_t sbits = f16_from_f32(amax / 127.0f);' \
                     'const uint16_t sbits = f16_from_f32(fabsf(amax / 127.0f) > 65504.0f ? (amax < 0.0f ? -65504.0f : 65504.0f) : amax / 127.0f);'

    # (4) the prompt path's int8 KV append, which uses this file's own hf().
    # hf_sat is the saturating form already used for the SwiGLU products.
    substituteInPlace src/prefill/kernels.cu \
      --replace-fail 'const uint16_t sb = hf(amax / 127.0f);' \
                     'const uint16_t sb = hf_sat(amax / 127.0f);'

    # (5) Make the finiteness guard's mid-stream error RETRYABLE for the coding
    # agent. Pi's agent-level auto-retry (retry.enabled, on by default) decides
    # from the error message TEXT alone: it matches transient patterns such as
    # `server.?error`, and "verify: non-finite logits" matches none of them, so a
    # guard fire ended the session (session 01a1099d-927e-76ba-87c0-9abc71fa1df9,
    # 2026-10-05 12:47) instead of reloading the engine and repeating the turn.
    # Prefix the engine's post-stream ERR (ValueError) and the EngineDied path
    # with "server error", so Pi classifies them retryable: the retried request
    # blocks in StrataEngine.restart() until the engine says READY (~30-60 s),
    # then the turn runs again by itself. The canonical audit lines
    # ("strata verify: ...") and the engine's own error string are untouched.
    #
    # This is re-applied in installPhase (not here): installPhase copies the
    # Python layer from the pristine ${finalAttrs.src}, so a rewrite of the
    # build tree's serve/ never reaches the package. postPatch here would be a
    # no-op for the installed file, so the substituteInPlace lives below.
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

    # (5, cont.) the retryable-guard rewrite, on the installed copy (see the
    # postPatch comment). substituteInPlace only uses sed, so it is safe here.
    substituteInPlace $out/share/strata/serve/server.py \
      --replace-fail \
        'err = {"error": {"type": "server_error", "message": f"{e}; the next request restarts it"}}' \
        'err = {"error": {"type": "server_error", "message": f"server error: {e}; the next request restarts it"}}' \
      --replace-fail \
        'err = {"error": {"type": "server_error", "message": str(e)}}   # headers are sent, so no 400 now' \
        'err = {"error": {"type": "server_error", "message": "server error: " + str(e)}}   # headers are sent, so no 400 now'

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
