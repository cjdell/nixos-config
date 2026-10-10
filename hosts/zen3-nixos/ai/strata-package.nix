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
  version = "0.1.42";

  # v0.1.42 (2026-10-10).  NOTE: upstream rewrote this repo's history on
  # 2026-10-06 (the 0.1.40.1 release notes say so), so any pin older than that has
  # no common ancestor with main and GitHub's compare API cannot diff them - diff
  # two trees instead.  The old tag v0.1.39 is also not 6f32ec0 (it is a1641e9f).
  #
  # 0.1.41 -> 0.1.42 (checked against the trees, not the changelog; only the files
  # this build touches are listed):
  #   * src/kernels/cuda/iq_kernels.cu - ONE hunk, and it is for us: #1474 extends the
  #     gfx1151 "half path's negative scale times +0 folds to +0" workaround (the
  #     `if constexpr (std::is_same_v<dst_t, __half>)` block, ~line 1708) to RDNA4
  #     gfx1200/gfx1201 (ROCm 7.10).  That is a HIP-compiler bug our card hits, so
  #     nothing to opt out of.  The q8_1 sites #1448 clamped stay clamped.
  #   * src/kernels/cuda/kv_q8.cu and src/prefill/kernels.cu are byte-identical to
  #     0.1.41 (0 changed lines): kv_q8.cu:55 and kv_append_kernel
  #     (prefill/kernels.cu:1691) are STILL unclamped, so postPatch clamps (2) and (3)
  #     stay - the int8 KV sites #606/#1448 never covered and the ones our
  #     132,947-token incident was fixed by.
  #   * src/core/verify.cpp - 161 changed lines, all unrelated to our guard: the
  #     STRATA_ROUTE_RESIDENT counters become per-GPU (a map+mutex, #1578), the
  #     logit_bias plumbing, a batch_rows/route_prior include, and an
  #     `always_publish_` fence test.  `patches` still applies with --fuzz=0: the 11
  #     verify.cpp hunks land in Verifier::init/run/record_window with pure offsets
  #     (+94 .. +108).  verify.hpp/sampler.hpp gained the logit_bias/rr_stats_ fields;
  #     our declaration hunks still land in the same sections (+6 / +1).
  #   * include/strata/kernels/iq_kernels.hpp - the ONE rebase our patch needed: a new
  #     A770 XMX port block (`kXmxGroupMax`, `iq_xmx_grouped`) was inserted between
  #     `native_expert_scratch_bytes` and the `native_expert_grouped` doc comment, so
  #     the hunk's trailing context moved.  Regenerated below; the added lines are
  #     byte-identical to the old diff (277 additions, 0 deletions).
  #   * serve/server.py - both installPhase rewrite targets still there verbatim (now
  #     lines 5269 and 5277).  New: a damaged llama.cpp archive is re-fetched (#1797),
  #     tool-set first-seen order is kept so the prompt cache survives (#1624),
  #     llama.cpp's repeat_penalty/repeat_last_n are accepted, and
  #     reasoning_loop_recovery catches a loop written as one long word (#1753).
  #   * AMD/gfx1201: the gfx12 prompt switches (STRATA_GDN_HEAD, GDN_PP=2, GDN_CONVL2,
  #     GDN_NOY, CVEC_FUSE) are ON by default (#1478) - residual/logits byte-identical
  #     at 4K/20K, prompt +0.8%/+1.6%/+1.8% at 4K/16K/32K; STRATA_GFX12_DEFAULTS=0
  #     turns them off.  The two new default changes (STRATA_ROUTE_TAIL_SKIP=7 and the
  #     measured PCIe share) are CUDA-only and off on AMD, so no answer change here and
  #     nothing to pin back.  Upstream's R9700 rows vs 0.1.41 are +0.03%/+0.1% decode,
  #     +0.9%/+0.3% prompt; the identity checks include the R9700 (one card, 2-card
  #     split, gfx12 switches on and off).
  #   * #879 (the routed-expert garbage our guard exists for) is STILL OPEN upstream
  #     (updated 2026-10-10) and no 0.1.42 change references it, so `patches` stays
  #     relevant.
  # The ggml pin is unchanged too (setup.py:166 LLAMA_CPP_COMMIT = 3cf03257...).
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "61b3fb5dd3f1e8ec09cf7e4e05208bc6d3c46406";
    hash = "sha256-FPwm4cuGTFiXgWkK5eTcfD9VIrH/OnVZiG6ToQFOfMQ=";
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
  # (gist 66419118nnn/7c9399d982d98229c61fcefaaa0b9215), re-based onto our exact
  # pin 61b3fb5d (v0.1.42) on 2026-10-10; all 19 hunks now apply with --fuzz=0 and
  # NO offsets (checked against the fetched source), and the hunks still land in
  # Verifier::run/record_window and inside native_expert_grouped - the #879 suspect
  # site is untouched upstream.  The only hunks that needed a re-base were the
  # iq_kernels.hpp declaration block (0.1.42's new A770 XMX declarations moved its
  # trailing context); every other file applied with offsets, and the added lines are
  # byte-identical to the 0.1.40.2/0.1.41 diff (277 additions, 0 deletions - verified
  # by diffing the + lines of the two patch files).  Regenerated from the patched
  # tree, so every hunk applies with --fuzz=0; do not re-apply the old file with fuzz
  # (fuzz 3 once put the arena carve inside the mapped() chain and the input audit
  # inside the PLE try block).  #879 proved the repeated-token
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

  # Activation quantizers must keep their fp16 scale and sum finite: a value past
  # fp16's 65504 rounds to +inf, the dequantised dot product then reads inf * 0 =
  # NaN, and a NaN in the residual makes the model answer one token forever -- the
  # degeneracy the guard in serve/server.py exists to end (upstream #606;
  # ggml-org/llama.cpp#23606 is the same defect).
  #
  # STATUS ON 0.1.42 (checked against the tree, not the changelog): 0.1.42 changed
  # NONE of the clamp sites - kv_q8.cu and prefill/kernels.cu are byte-identical to
  # 0.1.41 - and upstream #1448
  # ("q8_1 scale overflow at the three remaining emit sites is clamped like the
  # others") landed in 0.1.41 and took over one of ours.  The three sites our 0.1.39
  # build clamped itself are all fixed upstream now - native_mmvq.cu
  # native_swiglu_quantize_q8_1_kernel (0.1.40), the iq_kernels.cu fused gate/up block
  # store (0.1.40), and the S26 fused swiglu+q8_1 kernel (iq_kernels.cu
  # s26_swiglu_q8_1_kernel, ~line 2323) which was ours until 0.1.41 and uses
  # q8_1_finite/q8_1_quant/q8_1_ds exactly as we wrote it.  That clamp is therefore
  # GONE here: its target strings no longer exist and --replace-fail would break the
  # build.  What is still unclamped upstream, and still ours:
  #   * the int8 KV cache block scale, decode (kv_q8.cu:55) and prompt
  #     (kv_append_kernel, prefill/kernels.cu:1691 - it moved from 1340) - never
  #     covered by #606 nor by #1448, and the site our incident-2 132,947-token
  #     prompt was fixed by.  Still live: we run --kv int8.
  # #1448 also clamped the two sites we had deliberately left alone - fused_gr.cu
  # gr_q8_tail and verify_kernels.cu gdn_q8_1_store, both behind STRATA_QFUSE (off on
  # gfx1201) - so that "re-visit if STRATA_QFUSE is ever turned on" note is closed:
  # upstream owns those clamps now.  The only q8_1 ds store left that does not go
  # through q8_1_ds in 0.1.41/0.1.42 is native_mmvq.cu:1985, which writes a fixed synthetic
  # scale (0.001 + r*1e-9), not an amax-derived one, so it cannot overflow.
  #
  # Clamp each to the largest finite half with the same q8_1_finite/q8_1_quant/
  # q8_1_ds helpers the fixed siblings use (or this file's hf_sat). A block that was
  # finite before is stored bit for bit as before -- values in (65504, 65520) round
  # to 65504 anyway, and a finite block's |x / d| is at most 127 -- and a NaN stays
  # NaN, so STRATA_DBG_NAN still finds it.
  postPatch = ''
    # (1) was the S26 fused swiglu + q8_1 kernel clamp.  Upstream #1448 shipped the
    # identical clamp in 0.1.41, so it is dropped here - do not add it back, the
    # --replace-fail targets are gone from the file.

    # (2) the int8 KV cache block scale (--kv int8): a 64-value group's
    # amax / 127 is stored fp16, so it saturates to inf past amax = 8.3M and the
    # gather's q * inf = NaN poisons attention for every later token. Decode
    # append here; the prompt append is in prefill/kernels.cu (patched below).
    substituteInPlace src/kernels/cuda/kv_q8.cu \
      --replace-fail 'const uint16_t sbits = f16_from_f32(amax / 127.0f);' \
                     'const uint16_t sbits = f16_from_f32(fabsf(amax / 127.0f) > 65504.0f ? (amax < 0.0f ? -65504.0f : 65504.0f) : amax / 127.0f);'

    # (3) the prompt path's int8 KV append, which uses this file's own hf().
    # hf_sat is the saturating form already used for the SwiGLU products.
    substituteInPlace src/prefill/kernels.cu \
      --replace-fail 'const uint16_t sb = hf(amax / 127.0f);' \
                     'const uint16_t sb = hf_sat(amax / 127.0f);'

    # (4) Make the finiteness guard's mid-stream error RETRYABLE for the coding
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

    # (4, cont.) the retryable-guard rewrite, on the installed copy (see the
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
