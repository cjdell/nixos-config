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
  version = "0.1.44.1";

  # v0.1.44.1 (2026-10-14, rev 296b59d2) - the hotfix on 0.1.44 (2026-10-13), which follows
  # 0.1.43.1 (2026-10-12).  NOTE: upstream rewrote this repo's history on 2026-10-06 (the
  # 0.1.40.1 release notes say so), so any pin older than that has no common ancestor with
  # main and GitHub's compare API cannot diff them - diff two trees instead.
  #
  # 0.1.43 -> 0.1.44.1 (checked against the trees, not the changelog; only what this build
  # touches).  EVERYTHING OF OURS STILL APPLIES - nothing was dropped:
  #   * THE AUDIT PATCH IS STILL THE ONLY NON-UPSTREAM CODE.  #879 is still OPEN (the
  #     maintainer still could not fire it) and 0.1.44/0.1.44.1 do not touch the routed-expert
  #     data path, so ./strata-kernel-audit.diff stays.  Re-based onto 296b59d2 on 2026-10-14:
  #     19 hunks, 280 additions, 0 deletions, --fuzz=0 with NO offsets (regenerated from the
  #     patched tree, so `patch -p1 --fuzz=0` and `git apply --check` are both clean).  Before
  #     regeneration the hunks landed at offsets +11 (verify.hpp), +4 (iq_kernels.hpp),
  #     +22/+35/+134 (verify.cpp) and +190/+206 (iq_kernels.cu); sampler.hpp and sampler.cu
  #     were already exact.  The added lines are BYTE-IDENTICAL to the 0.1.43 file - only the
  #     hunk line numbers moved.  Its dependencies are all still there: the guard it rides on
  #     (logits_nonfinite_rows verify.cpp:1830, Verifier::note_nonfinite setting nf_mask_
  #     verify.cpp:3311-3329, EngineNonFinite + nf_retried in serve/server.py:327/1551/4123/
  #     4327) and the `hits_in_combine` gate the routed-total probe checks (verify.cpp:1624/
  #     1677/1680/1692 - still in verify.cpp, not moved to a kernel file).
  #   * THE GUARD IS STILL UPSTREAM'S (#1892, on by default, STRATA_NAN_GUARD=0 off): the
  #     poisoned window emits nothing, every cached state is dropped so the next request
  #     re-reads the prompt from token 0, and serve/server.py retries once.  Our own guard was
  #     removed in 0.1.43 (two guards behind one env var); do not add it back.
  #   * THE TWO q8_1/int8 CLAMPS ARE STILL OURS.  0.1.44 changed NONE of the clamp sites:
  #     src/kernels/cuda/kv_q8.cu is byte-identical to 0.1.43 (0 changed lines) so clamp (2)
  #     still targets kv_q8.cu:55, and src/prefill/kernels.cu's 27 changed lines are the NVFP4
  #     `row_sd` in moe_combine_kernel/moe_combine4_kernel plus a gfx1103 WMMA case - clamp (3)'s
  #     target `const uint16_t sb = hf(amax / 127.0f);` is still there exactly once, now at
  #     prefill/kernels.cu:1702 (was 1691), and hf_sat is still defined at :48.  Both still
  #     live because we run --kv int8.
  #   * serve/server.py: 661 changed lines, but BOTH installPhase rewrite targets are still
  #     present exactly once (now 5861 and 5869), so the "server error" prefix that makes our
  #     remaining hard errors retryable by Pi still applies.  CAUTION if we ever move to the
  #     Responses or Anthropic routes: 0.1.44 added four more `the next request restarts it`
  #     error paths that our rewrite does NOT match (5559, 5933, 5966, 6085 - the 503, Responses
  #     and Anthropic exits).  Pi talks to /chat/completions, so today's coverage is complete.
  #   * Build surface unchanged: no install() rules (installPhase still hand-installs), the
  #     binary is still add_executable(strata src/program/generate.cpp) (CMakeLists.txt:622),
  #     every cmake flag we pass is still an option, serve/ + tools/ + data/ still exist
  #     (serve/images.py and data/quant_quality are new; `cp -r` covers both), serve/ gained
  #     NO new third-party import (still jinja2 / PIL / psutil - serverPython is unchanged),
  #     and all 13 engine args in ./strata.nix are still parsed.  Upstream added its own
  #     flake.nix (#2198) - we keep ours, it builds CUDA/HIP with its own target lists.
  #   * AMD/gfx12 behaviour changes to EXPECT (no config change needed, but they move answers
  #     or speed - these are the ones to A/B if an answer changes after this deploy):
  #       - NEW IN 0.1.44: STRATA_HC_Q8 IS ON BY DEFAULT ON RDNA4 (native_dense.cpp:46-70
  #         hc_q8_env, gated on gfx_arch_is_gfx12 under HIP).  The hyper-connection projections
  #         are read as Q8_0 instead of BF16: R9700 decode +2.5..4%, mean KL 0.0003-0.0010,
  #         "answers can differ in near-ties".  For OUR pack (repacked with --compat-bf16, so
  #         its 195 hc_* tensors are BF16 in the pack) the engine quantizes that BF16 copy back
  #         to Q8_0 at load (fused_gr.cu:2090 gr_quantize_q8_0_kernel) - the bf16-pack path is
  #         deliberate, not an accident, and it costs a little load time and hc_q8_bytes of
  #         extra arena (logged at native_dense.cpp:496).  Revert: STRATA_HC_Q8=0, or
  #         STRATA_GFX12_DEFAULTS=0 for this AND the chunk change below.
  #       - NEW IN 0.1.43/0.1.44: a bare `--prefill auto` (which we pass) may chunk prompts at
  #         16384 instead of 8192 on gfx12 (generate.cpp:2255-2272).  0.1.44's #2090 guard
  #         (generate.cpp:6634) drops back to 8192 when available RAM does not cover the extra
  #         slot loan + 6 GiB, which matters here because we run --resident-budget-gib 55 on
  #         94 GB.  STRATA_GFX12_CHUNK=0 keeps 8192, =1 forces 16384.
  #       - UNCHANGED FROM 0.1.43: STRATA_ROUTE_TAIL_SKIP=7 and the measured PCIe share stay
  #         on for gfx1200/gfx1201 (we sit at 43% of experts in the GPU cache, so the skip is
  #         ON; KL ~0.003-0.006).  STRATA_ROUTE_TAIL_SKIP=0 --pcie-frac 0 is the A/B the
  #         maintainer asks for while hunting #879.
  #       - NEW IN 0.1.44, bit-identical per upstream: STRATA_COMMIT_BATCH (one commit-graph
  #         launch per layer kind, verify.cpp:2041, =0 keeps the per-layer loop) and
  #         STRATA_MTP_HIP_PRIO (the draft stream at high priority on gfx1200/gfx1201,
  #         mtp.cpp:445).  STRATA_PF_FUSED's gfx12 default still covers IQ3_S/IQ3_XXS gate/up
  #         ONLY, so our UD-IQ4_XS pack keeps MMQ - no answer change from it.
  #   * From 0.1.43.1, both relevant to this box: the prompt path's pageable host->GPU copies
  #     now go through a ring of PINNED buffers (#1996, an RX 7900 XTX memory-access fault after
  #     ~30 min; a 65-min 6-client R9700 stress ran clean) - we stream KV to host RAM with
  #     --kv-resident, so this is the same class of bug; and the PLE n-gram table is no longer
  #     switched to mmap by itself (the start-up check only warns now, STRATA_PLE_AUTO_MMAP=1
  #     brings the 0.1.42 switch back) with the watchdog's slow-disk allowance widened - our
  #     26.82 GiB PLE table is read with direct IO, and the 0.1.42 auto-mmap made SATA prompts
  #     ~7x slower (#2040).  Also fixed: a short prompt right after start ending the engine with
  #     "lending the prompt path its slots failed" (#2090).
  #   * From 0.1.44, likely useful: serve/server.py:528 START_RETRIES (default 3) retries a
  #     server start that dies inside the GPU runtime's own set-up - "a ROCm hsa_exception one
  #     start in twenty after a quick restart" - at 2, 4 and 8 s.  That is our flaky-restart
  #     class; STRATA_START_RETRIES=0 turns it off.
  #   * NOT APPLICABLE HERE (checked so nobody re-reads the changelog): NVFP4 packs (NVIDIA
  #     only), Qwen3.6-35B-A3B, the Mac/Metal engine, the Intel Arc work, RDNA4 MULTI-GPU
  #     pipelining (one card here), STRATA_MMQ_KQ (K-quants only - IQ4_XS is not one),
  #     --adapt-async and STRATA_PIN_BY_NEED (both off by default), and all of 0.1.44.1's
  #     hotfixes (non-AVX2 CPUs, CUDA 12.0/12.1 builds, Apple M2 gdn_step, setup's model-size
  #     default, Responses reasoning_effort).
  #   * Checked and NOT a new fp16-overflow exposure: 0.1.44's new fp16 scale stores from
  #     amax/127 are gr_quantize_q8_0_kernel (fused_gr.cu:2099 - WEIGHTS, bounded by the
  #     projection magnitudes, not activations) and quantize_act.cu (byte-identical to 0.1.43).
  #     s2_expert_grouped.cu:193 does store an unclamped Q8_0 activation scale, but it predates
  #     this pin and 0.1.44 only added a geometry static_assert to that file.
  #   * #879 (the routed-expert garbage the audit exists for) is STILL OPEN upstream, so
  #     `patches` stays relevant - just for the audit, not the guard.
  # The ggml pin is unchanged (setup.py:167 LLAMA_CPP_COMMIT = 3cf03257..., same rev as
  # 0.1.41/0.1.42/0.1.43), so the `llama` fetch above stays exactly as it was.
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "296b59d2f73c8f04a805df29c2fa97655adace78";
    hash = "sha256-Jfo2uldtyXW8Y/wQxA7WcYwtmzCGAOaXgnlMSo7K9LE=";
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

  # Our kernel AUDIT port (2026-10-05, from the 0.1.35 audit build; the HIP-adapted copy
  # of the upstream #879 reporter's instrumentation, gist 66419118nnn /
  # 7c9399d982d98229c61fcefaaa0b9215), re-based onto our exact pin 296b59d2 (v0.1.44.1) on
  # 2026-10-14: all 19 hunks apply with --fuzz=0 and NO offsets (checked against the fetched
  # tree with both `patch -p1 --fuzz=0` and `git apply --check`), landing in
  # Verifier::init/record_window/run and inside native_expert_grouped - the #879 suspect site,
  # still untouched upstream (0.1.44's 300 changed lines in iq_kernels.cu are the route-resident
  # work and the NVFP4 dequant paths, not the grouped-expert MMQ kernels).  The 280 added lines
  # are byte-identical to the 0.1.43 file - only the hunk line numbers moved.  Regenerated
  # from the patched tree, so every hunk applies with --fuzz=0; do not re-apply an old
  # file with fuzz (fuzz 3 once put the arena carve inside the mapped() chain and the
  # input audit inside the PLE try block).  #879 proved the repeated-token degeneration
  # is NOT the fp16-overflow class the postPatch clamps below fix: the first poisoned
  # value is garbage 0x7FFFFFFF bits written into a routed-expert output row (a data-path
  # defect in native_expert_grouped).
  #
  # THIS PATCH NO LONGER CONTAINS A GUARD.  0.1.43 shipped upstream's own (#1892), on by
  # default, on the same STRATA_NAN_GUARD switch, and it recovers instead of erroring: the
  # poisoned window emits nothing, the engine drops every cached state, re-reads the prompt
  # from token 0 and serve/server.py retries the request once.  Ours only failed the window,
  # so keeping both would have meant two guards behind one env var and the worse recovery
  # winning whenever ours saw the window first.  What is left is the part upstream does not
  # have - WHERE the poison was born:
  #   * opt-in per-stage audit kernels (STRATA_KERNEL_AUDIT=1, set in ./strata.nix) that
  #     record the first non-finite (layer, row, col, raw bits) at each of the four
  #     grouped-expert stages, plus the attention/shared/routed/GPU-hit/CPU-miss rows and
  #     the layer's folded input; HIP-safe: pure cuda* shims + <<<>>> the tree builds.
  #   * a dump in Verifier::run that prints those flags - every fire, not just the first -
  #     triggered by upstream's own nf_mask_, so it costs nothing on a healthy window and
  #     nothing at all with STRATA_KERNEL_AUDIT=0 (the flags are never allocated).
  patches = [ ./strata-kernel-audit.diff ];

  # Activation quantizers must keep their fp16 scale and sum finite: a value past
  # fp16's 65504 rounds to +inf, the dequantised dot product then reads inf * 0 =
  # NaN, and a NaN in the residual makes the model answer one token forever -- the
  # degeneracy the guard in serve/server.py exists to end (upstream #606;
  # ggml-org/llama.cpp#23606 is the same defect).
  #
  # STATUS ON 0.1.44.1 (checked against the tree, not the changelog): 0.1.44 changed
  # NONE of the clamp sites - kv_q8.cu is byte-identical to 0.1.43 (0 changed lines) and
  # prefill/kernels.cu's 27 changed lines are NVFP4 `row_sd` in the moe_combine kernels plus a
  # gfx1103 WMMA case - and upstream #1448
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
  #     (kv_append_kernel, prefill/kernels.cu:1702 - it moved from 1691 in 0.1.43 and from 1340
  #     in 0.1.42) - never covered by #606 nor by #1448, and the site our incident-2
  #     132,947-token prompt was fixed by.  Still live: we run --kv int8.  Both --replace-fail
  #     targets are still UNIQUE in their file (checked on 296b59d2).
  # #1448 also clamped the two sites we had deliberately left alone - fused_gr.cu
  # gr_q8_tail and verify_kernels.cu gdn_q8_1_store, both behind STRATA_QFUSE (off on
  # gfx1201) - so that "re-visit if STRATA_QFUSE is ever turned on" note is closed:
  # upstream owns those clamps now.  The only q8_1 ds store left that does not go
  # through q8_1_ds is native_mmvq.cu:2074 (was 1985), which writes a fixed synthetic
  # scale (0.001 + r*1e-9), not an amax-derived one, so it cannot overflow.  Re-checked on
  # 0.1.44.1: the ONE new q8_1 emit site upstream added (fused_gr.cu, the STRATA_HC_Q8 bf16
  # read) already goes through q8_1_finite/q8_1_quant/q8_1_ds, and native_mmvq.cu,
  # verify_kernels.cu and iq_kernels.cu gained no unclamped amax-derived fp16 store - the only
  # other new fp16 writes are gr_quantize_q8_0_kernel (fused_gr.cu:2099, WEIGHTS, bounded) and
  # the NVFP4 dequant scales (iq_kernels.cu:2071/2088, prefill/kernels.cu moe_combine row_sd),
  # which never run here: NVFP4 is NVIDIA-only.
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
