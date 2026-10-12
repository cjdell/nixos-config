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
  version = "0.1.43";

  # v0.1.43 (2026-10-11, rev 7695859a).  NOTE: upstream rewrote this repo's history on
  # 2026-10-06 (the 0.1.40.1 release notes say so), so any pin older than that has
  # no common ancestor with main and GitHub's compare API cannot diff them - diff
  # two trees instead.  The old tag v0.1.39 is also not 6f32ec0 (it is a1641e9f).
  #
  # 0.1.42 -> 0.1.43 (checked against the trees, not the changelog; only the files
  # this build touches are listed):
  #   * THE HEADLINE FOR US: upstream shipped the #879 finiteness GUARD (#1892 by
  #     lask3802), ON BY DEFAULT and behind the SAME `STRATA_NAN_GUARD` switch our patch
  #     had invented, so our guard is GONE from ./strata-kernel-audit.diff (the file is
  #     renamed for exactly that reason).  What upstream does: every window graph records
  #     `logits_nonfinite_rows(head_logits_, T, n_vocab, m_nf_)` (verify.cpp:1795),
  #     `Verifier::note_nonfinite` sets nf_row_/nf_pos_/nf_mask_ after the window sync,
  #     generate.cpp ends the request `DONE ... nonfinite` emitting NONE of the poisoned
  #     window's tokens and drops every cached state (the next request re-reads the prompt
  #     from token 0), and serve/server.py raises EngineNonFinite and retries the request
  #     once (`nf_retried`).  Engine log line: `non-finite logits (#879)`; cost <=0.2%
  #     decode, `STRATA_NAN_GUARD=0` off.  Strictly better than ours, which failed the
  #     window with "verify: non-finite logits" and only reached a retry because rewrite
  #     (4) below made it a "server error" Pi would accept.  Keeping both would also have
  #     left two guards on one env var, so which one answered first was luck.
  #   * What upstream does NOT have is WHERE the poison is born - #879 is still OPEN
  #     (updated 2026-10-11; the maintainer could not fire it in 1,870 R9700 requests or
  #     276 MMQ kernel cases) - so the AUDIT half stays and is now the only non-upstream
  #     thing in the diff: 19 hunks, 280 additions, 0 deletions, --fuzz=0 with NO offsets
  #     on 7695859a.  Two changes while re-basing, both about cost:
  #       - `lay_flags_` (the per-stage poison flags) is allocated ONLY with
  #         STRATA_KERNEL_AUDIT=1.  Until now it was allocated always, so ~10 audit
  #         launches per layer sat in every captured window graph whether anyone was
  #         looking or not; 0.1.43 priced exactly that (it ships STRATA_DUMMY_NODES to
  #         measure "one empty kernel node per layer" and wins 1.6-2.0% decode by
  #         removing and fusing decode-window nodes), so paying it silently was the wrong
  #         trade.  Every write site is gated on the pointer, so with the audit off the
  #         window graph matches upstream's.  ./strata.nix still sets it to 1 - we are
  #         mid-hunt and the maintainer asked for capture data.
  #       - the failure dump moved and no longer fails anything: it rides on upstream's
  #         nf_mask_ instead of its own scan, prints EVERY fire (upstream's
  #         STRATA_DBG_NAN reports the first only, and the maintainer asked for more than
  #         one), and reads only memory the window already wrote.  It needs
  #         STRATA_NAN_GUARD unset (those are the flags it reads) and
  #         STRATA_KERNEL_AUDIT=1 for the per-layer lines.
  #   * Three audit sites needed a re-base; the other 16 hunks moved by offset alone:
  #       - the layer-input site: 0.1.43 inserted the STRATA_DUMMY_NODES probe between
  #         `q8_attn = gr_read_group(...)` and `if (inputs_pending)`.
  #       - the attention-output site: a new `stamp(l, 32, grp)` profile line after
  #         `q8_ffn = gr_read_group(...)`.
  #       - the routed-total site: 0.1.43's fused combine made the hit add CONDITIONAL
  #         (`hits_in_combine`, fuse_hits_on, the decode default) -
  #         `native_moe_combine_multi_hits_added` folds it inside the combine, so
  #         `parts_out` is not the routed total there and sampling it would have lied.
  #         That probe is now gated `&& !hits_in_combine`; the hit_out and miss-row probes
  #         moved before the add (moe_hit_add only reads hit_out, so they see the same
  #         bytes), and site 4 (the layer's whole contribution, after the combine) still
  #         covers the fused case.
  #   * src/kernels/cuda/kv_q8.cu and src/prefill/kernels.cu are byte-identical to 0.1.42
  #     (0 changed lines) again: kv_q8.cu:55 and kv_append_kernel
  #     (prefill/kernels.cu:1691) are STILL unclamped, so postPatch clamps (2) and (3)
  #     stay - the int8 KV sites #606/#1448 never covered, live because we run --kv int8.
  #   * include/strata/kernels/iq_kernels.hpp: 0 changed lines, so last release's one
  #     re-base (the A770 XMX block that had moved that hunk's trailing context) is stable.
  #   * src/kernels/cuda/iq_kernels.cu: 6 changed lines (the #1737 route-resident work);
  #     our four audit hunks land with offset 4 and the q8_1 emit sites #1448 clamped stay
  #     clamped upstream - nothing here reintroduces a clamp of ours.
  #   * src/core/verify.cpp: 242 changed lines, almost all of it the #1892 guard above
  #     (plus STRATA_NAN_INJECT for testing it and the pipelined-window hooks); our
  #     remaining hunks still land in Verifier::init/record_window/run.
  #   * serve/server.py: 138 changed lines; both installPhase rewrite targets are still
  #     there verbatim (now 5392 and 5400), so the "server error" prefix that makes our
  #     remaining hard errors retryable by Pi still applies.  New around them: the #879
  #     EngineNonFinite retry, timings fixes (#1869/#1870) and STRATA_DROP_CACHE_ON_EXIT
  #     (opt-in, off - and keep it off: it posix_fadvise(DONTNEED)s the model files on
  #     exit, and the warm page cache is what makes a restart take seconds).
  #   * AMD/gfx1201 behaviour changes to EXPECT (no config change needed, but they move
  #     answers): the two decode defaults NVIDIA got in 0.1.42 now apply here too -
  #     STRATA_ROUTE_TAIL_SKIP=7 (generate.cpp:8203; it stays off only from 90% of the
  #     experts in the GPU cache on one card, and we sit at 10,679 of 24,576 = 43%, so it
  #     is ON: KL ~0.003-0.006, answers differ slightly from 0.1.42) and the measured
  #     PCIe share (STRATA_PCIE_FRAC_DEFAULT=old reverts it).  STRATA_PF_FUSED's new
  #     gfx12 default covers IQ3_S/IQ3_XXS gate/up ONLY
  #     (moe_fused_iq.cu:1131 `if (env < 0 && gu_type != T_IQ3_S && gu_type != T_IQ3_XXS)
  #     return false;`), so our UD-IQ4_XS pack keeps MMQ - no answer change from it.
  #     Long prompts may now chunk at 16384 (STRATA_GFX12_CHUNK=0 keeps 8192).  Note the
  #     tail skip and the PCIe share are two of the variables the maintainer asks us to
  #     pin while hunting #879: `STRATA_ROUTE_TAIL_SKIP=0 --pcie-frac 0` is the A/B.
  #     Upstream's R9700 rows vs 0.1.42: decode +2..10% (IQ3_S +6..14%), prompt
  #     +12..14% (32K +17%, 64K +27%); with a 16 GB card's cache +21..38%.
  #   * #879 (the routed-expert garbage the audit exists for) is STILL OPEN upstream, so
  #     `patches` stays relevant - just for the audit, not the guard.
  # The ggml pin is unchanged (setup.py:166 LLAMA_CPP_COMMIT = 3cf03257..., same rev as
  # 0.1.41/0.1.42), so the `llama` fetch above stays exactly as it was.
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "7695859aa13afb248bdb4d36f9b2e95707db079d";
    hash = "sha256-SjhgL3wXV36a4AuDlrQH9E9PDAOAqDS6dXMuVM5/5yw=";
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
  # 7c9399d982d98229c61fcefaaa0b9215), re-based onto our exact pin 7695859a (v0.1.43) on
  # 2026-10-12: all 19 hunks apply with --fuzz=0 and NO offsets (checked against the
  # fetched tree), landing in Verifier::init/record_window/run and inside
  # native_expert_grouped - the #879 suspect site, still untouched upstream.  Regenerated
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
  # STATUS ON 0.1.43 (checked against the tree, not the changelog): 0.1.43 changed
  # NONE of the clamp sites - kv_q8.cu and prefill/kernels.cu are byte-identical to
  # 0.1.41 and 0.1.42 - and upstream #1448
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
