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
# layer, plus `strata-vision` (the image encoder of the multimodal path, see
# `postBuild` below). Model data (GGUF, packs, MTP runtime, mmproj) is NOT in
# the store: it is prepared once by hand and passed via a JSON run config (see
# ./strata.nix).
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
  # only used by the one-time pack tools, bundled for convenience.  0.2.1.1
  # adds NO required import: jsonschema/referencing stay a lazy optional
  # import in serve/structured.py (absent -> "one JSON object" only), and
  # textual/requests/tqdm are Terminal/monitor-only.
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
  version = "0.2.1.1";

  # v0.2.1.1 (2026-10-20, rev 9ae93f7b) - the Windows-Terminal hotfix on 0.2.1 (2026-10-20), which follows
  # 0.2.0-beta (10-19) and 0.1.45 (10-17).  0.2.0 re-cut the repo into APP + TERMINAL + ENGINE: the release
  # notes' "engine package 0.1.46" is the source in this tag (CMakeLists.txt:7 `project(strata VERSION
  # 0.1.46.1)`); the new apps/, bin/, docker/, integrations/ and packaging/ trees and strata_cli/ +
  # strata_control/ + strata.py are the app and the Terminal.  We still build only the engine + serve
  # layer from source - but see the installPhase note: serve/ now IMPORTS strata_control/strata_cli, so
  # those two Python packages ship with the engine now.  NOTE: upstream rewrote this repo's history on
  # 2026-10-06, so pins older than that have no common ancestor with main - diff two trees, not GitHub.
  #
  # 0.1.44.1 -> 0.2.1.1 (checked against the trees, not the changelog; only what this build touches):
  #   * THE AUDIT PATCH IS STILL THE ONLY NON-UPSTREAM CODE, AND #879 IS NOT DEAD.  The maintainer closed
  #     #879 on 2026-10-13 as a stale-tracker sweep ("issues older than three days... comment and we will
  #     reopen"), but on 2026-10-19 a fresh repro landed on it (still closed): engine 0.1.45, RTX 3080, an
  #     18,442-token agent prompt with 48 tool schemas -> `non-finite logits (#879)` at the last window
  #     EVERY time, `STRATA_PREFILL_MMQ=0` answers the same body, and STRATA_DBG_NAN puts the birth in
  #     LAYER 1's MoE gate/up on the MMQ PROMPT path, types 22/42 - IQ4_XS gate/up, our pack's family.  So
  #     the audit stays - it is still the only instrumentation.  Re-based onto 9ae93f7b on 2026-10-20:
  #     19 hunks, 280 additions, 0 deletions, --fuzz=0 with NO offsets (regenerated from the patched tree,
  #     `patch -p1 --fuzz=0` and `git apply --check` both clean), added lines BYTE-IDENTICAL to the
  #     0.1.44.1 file.  Five hunks needed real work: verify.cpp's audit_alloc insert (upstream added the
  #     hand-off-counter block right after the arena memset), the per-window reset (a keep_rows line now
  #     follows hrow0), audit_hit_rows (a new m_bal_ branch moved into the trailing context of the hit_out
  #     grouped call), and in iq_kernels.cu the definitions block (new expdec setters between
  #     native_grouped_set_v1 and native_expert_grouped) and the stage-2 audit (the sw_v1 branch grew
  #     `|| L.had_block > 0` and a hadamard_rows call).  The other 14 landed with offsets up to +1159 -
  #     iq_kernels.cu gained ~1,100 lines (the S26/S27 v2/v2k expert paths; v2 is STRATA_EXPERT_V2=1
  #     opt-in, v2k is default-on for Q4_K/Q5_K gate/up, NEITHER matches our IQ4_XS geometry, so our model
  #     still runs the audited kernels).  sampler.cu is byte-identical to 0.1.44.1, sampler.hpp exact.  The
  #     guard it rides on is untouched: the 0.1.44.1->0.2.1.1 server.py diff (1,560 changed lines) touches
  #     NO non-finite line (EngineNonFinite, nf_retried, the retry path all intact), and logits_nonfinite_rows,
  #     note_nonfinite (x6) and hits_in_combine (x4) are still in verify.cpp.
  #   * THE GUARD IS STILL UPSTREAM'S (#1892, on by default, STRATA_NAN_GUARD=0 off): the poisoned window
  #     emits nothing, every cached state is dropped so the next request re-reads the prompt from token 0,
  #     and serve/server.py retries once.  Our own guard was removed in 0.1.43; do not add it back.
  #   * THE TWO q8_1/int8 CLAMPS ARE STILL OURS AND STILL UNCLAMPED UPSTREAM.  kv_q8.cu changed this time,
  #     but only by ADDING a STRATA_EXPERIMENTAL_SM60-gated 8-wide gather below the shipped kernels: the
  #     append's `const uint16_t sbits = f16_from_f32(amax / 127.0f);` is still at kv_q8.cu:55, unique,
  #     unclamped.  prefill/kernels.cu gained 769 changed lines; clamp (3)'s target
  #     `const uint16_t sb = hf(amax / 127.0f);` is still there exactly once, now at :2199 (was 1702), and
  #     hf_sat is still defined, now at :64 (was 48).  Both still live because we run --kv int8.
  #   * serve/server.py: BOTH installPhase rewrite targets are still present exactly once (now 6743 and
  #     6755, was 5861/5869), so the "server error" prefix that makes our remaining hard errors retryable
  #     by Pi still applies.  The uncovered `the next request restarts it` paths are still the 503 /
  #     Responses / Anthropic exits (6436, 6822, 6855, 6976) - Pi talks to /chat/completions, coverage
  #     complete.  The engine launch is unchanged: popen([exe, "--serve", *args]), and a config "vision"
  #     section still adds --vision (#1322) with --vram-reserve-mib only for a GPU reader.
  #   * NEW BUILD REQUIREMENT (the one real 0.2.x breakage): serve/server.py now imports the top-level
  #     `strata_control` package at module scope (engine_component, hipblaslt_tuning, vision_reader,
  #     draft_layer, user_args), and strata_control reaches `strata_cli` - both STDLIB-ONLY on that path,
  #     and strata_tokenizer is tools/strata_tokenizer.py, reachable via server.py's own sys.path insert.
  #     installPhase therefore copies strata_control/ and strata_cli/ next to serve/tools/data; without
  #     them `python -m serve.server` dies with ModuleNotFoundError.  Verified: `import serve.server`
  #     succeeds against exactly {serve,tools,data,strata_control,strata_cli} + the unchanged serverPython.
  #     Still NO new REQUIRED third-party import: jsonschema/referencing stay lazy+optional in
  #     serve/structured.py (absent -> "one JSON object" checking only, same as today), and textual /
  #     requests / tqdm (requirements.txt's new pins) are Terminal/monitor-only.
  #   * Build surface unchanged: no install() rules (installPhase still hand-installs), the binary is
  #     still add_executable(strata src/program/generate.cpp) (CMakeLists.txt:735, was 622), every cmake
  #     flag we pass is still an option, serve/ + tools/ + data/ still exist (expert-profile.bin,
  #     draft_vocab.bin, iq_pack.py --compat-bf16, mtp_fetch/mtp_pack/mtp_rt all still there),
  #     tools/vision still builds strata-vision with LLAMA_DIR / STRATA_VISION_CUDA / STRATA_PORTABLE -
  #     it gained STRATA_VISION_HIP (the AMD GPU picture reader, 57 ms vs 3.13 s per picture but ~1.4 GiB
  #     VRAM: we keep the CPU encoder, see the vision comment in ./strata.nix) - and all 19 engine args in
  #     ./strata.nix are still parsed.  The ggml pin is unchanged (setup.py:213 LLAMA_CPP_COMMIT =
  #     3cf03257..., same rev as 0.1.41-0.1.44), so the `llama` fetch above stays exactly as it was.
  #   * AMD/gfx12 behaviour changes to EXPECT (no config change needed, but they move answers or speed):
  #       - 0.1.45: Flash-Next answers BYTE-IDENTICAL to 0.1.44.1 on every machine upstream tested (HIP
  #         gfx1201 included).  Long prompts read faster with identical answers (R9700: 131K +8.7%, 230K
  #         +16%, 500K +79% - the #1749/#1943 top-k + exact-scorer work).  The 4096/2048/1024 chunk
  #         default, the new decode kernels and --parallel N in those notes are the Qwen3.6-35B-A3B
  #         family's or bit-identical; our Flash-Next path keeps its kernels.
  #       - 0.2.0/0.2.1: the engine opens its two busiest GPU queues in a fixed order at start
  #         (STRATA_HIP_QUEUE_PRIME, on for RX 9000/R9700 Linux): before it, ~half of fresh engines with
  #         MTP read prompts 8-14% slower depending on which compute pipe the firmware gave the queues
  #         (0/32 slow starts after, 10/32 before); answers identical.  Expect less start-to-start
  #         variance.  STRATA_HIP_QUEUE_PRIME=0 turns it off.
  #       - 0.2.1: a start-up drive probe for models read in place (#3237, STRATA_FILE_TIER_PROBE=0 off)
  #         reads 96 random 1 MiB pieces both ways (<2 s) and goes unbuffered only on a >=4 GB/s drive
  #         that wins; cannot change answers.  The compute-only-card reserve drop (1536 -> 512 MiB) does
  #         NOT apply here - "where the probe cannot tell (AMD and Intel on Linux) the safety default
  #         stays" - and no hipBLASLt tuning table ships for the Linux R9700 (opt-in only, and it is not
  #         bit-identical: first-token KL 0.016).
  #       - UNCHANGED: STRATA_HC_Q8 on by default for gfx12 (native_dense.cpp:46-60, still gated on
  #         gfx_arch_is_gfx12), STRATA_ROUTE_TAIL_SKIP=7 + the measured PCIe share, and the 16384 gfx12
  #         prompt chunk with the #2090 RAM guard (generate.cpp:2782/7427; STRATA_GFX12_CHUNK=0 keeps
  #         8192, STRATA_GFX12_DEFAULTS=0 reverts HC_Q8 too).  The 0.1.43/0.1.44 A/B notes in ./strata.nix
  #         still describe today's defaults.
  #   * NOT APPLICABLE HERE (checked so nobody re-reads the changelog): the app/Terminal/Docker/
  #     `strata bench run` layer, NVFP4, Qwen3.6-35B-A3B, Mac/Metal (now with a GPU picture reader),
  #     Intel Arc, RDNA4 multi-GPU pipelining (one card here), Flash-Next --parallel batching (0.1.45
  #     added it; we stay at one slot - docs/strata-batching.md), STRATA_IGPU_PROMPT_SET (780M/760M on
  #     Linux only), the hybrid-CPU core counting (5950X is not hybrid), STRATA_MMQ_KQ (K-quants only),
  #     and every STRATA_SLOT_* / multi-user switch from 0.1.45 (all opt-in, 4x R9700 rigs).
  #   * Checked and NOT a new fp16-overflow exposure: the new q8_1 emit sites are the v2k/S27 expert
  #     kernels (Q4_K/Q5_K only, not our geometry) and the experimental sm60 gather (gated off); the
  #     int8 KV scale stores our clamps cover are untouched.
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "9ae93f7b1fe989d04a8e404d32cddaeeff10505f";
    hash = "sha256-e7OIY0dNAxgDoQW99RXiZMgHGHmB5BohQGJ7bM/8QuE=";
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
  # 7c9399d982d98229c61fcefaaa0b9215), re-based onto our exact pin 9ae93f7b (v0.2.1.1) on
  # 2026-10-20: all 19 hunks apply with --fuzz=0 and NO offsets (checked against the fetched
  # tree with both `patch -p1 --fuzz=0` and `git apply --check`), landing in
  # Verifier::init/record_window/run and inside native_expert_grouped - the #879 suspect site,
  # still untouched upstream (0.2.x's ~1,900 changed lines in iq_kernels.cu are the S26/S27
  # v2/v2k expert paths and the NVFP4 dequant work, not our IQ4_XS kernels).  The 280 added
  # lines are byte-identical to the 0.1.44.1 file - only the hunk line numbers moved (five
  # hunks were re-placed by hand: see the src comment).  Regenerated
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
  # STATUS ON 0.2.1.1 (checked against the tree, not the changelog): 0.2.1.1 changed NEITHER
  # clamp site into a clamp - kv_q8.cu only ADDED a STRATA_EXPERIMENTAL_SM60-gated 8-wide gather
  # below the shipped kernels (the append at :55 is untouched), and prefill/kernels.cu's 769
  # changed lines add the Qwen3.6 prompt path and NVFP4 work, not a clamp of the int8 KV scale -
  # and upstream #1448
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
  #     (kv_append_kernel, prefill/kernels.cu:2199 - it moved from 1702 in 0.1.44.1, 1691 in
  #     0.1.43 and 1340 in 0.1.42; hf_sat is still defined above it, now at :64) - never covered
  #     by #606 nor by #1448, and the site our incident-2
  #     132,947-token prompt was fixed by.  Still live: we run --kv int8.  Both --replace-fail
  #     targets are still UNIQUE in their file (checked on 9ae93f7b).
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

  # strata-vision: the image encoder for image INPUT (`vision` in the run
  # config; OpenAI image_url parts / Anthropic image blocks -> mtmd -> the
  # engine's GENI prompt path). It is a SEPARATE CMake project —
  # `tools/vision/CMakeLists.txt` does its own `add_subdirectory(${LLAMA_DIR}
  # llama)` and builds `mtmd + llama` — so the engine build above does not
  # produce it, and upstream's installPhase-less layout means nothing else
  # installs it either. Same flags setup.py uses for an AMD box
  # (`build_vision_cpu`, setup.py:3035): CUDA OFF, and the same Release build
  # type. CUDA OFF is not a shortcut — `STRATA_VISION_CUDA` is the ONLY
  # GPU backend in that CMakeLists, and docs/AMD_HIP.md:52/203 is explicit that
  # on HIP images run through the CPU encoder. That costs no VRAM here (see the
  # `vision` comment in ./strata.nix), and it links ggml/llama from the SAME
  # pinned llama.cpp as the engine's ggml, so the embedding width matches the
  # pack (n_embd from `clip.vision.projection_dim`). It differs from setup.py in
  # one flag, PORTABLE, which is deliberate — see the STRATA_PORTABLE note.
  #
  # cwd is the CMake build dir from here on (cmake's setup hook `cd`s into
  # $cmakeBuildDir in configurePhase), hence the relative -B and the relative
  # path in installPhase below. No `-G Ninja`: this package has no `ninja` in
  # nativeBuildInputs, so the hook leaves buildPhase on `make` and the engine
  # itself configures with Unix Makefiles — asking for Ninja here fails the
  # configure with "unable to find a build program corresponding to Ninja".
  # The compiler flags mirror what cmakeConfigurePhase passes for the main
  # build (setup-hook.sh:32-35), since we invoke cmake directly.
  #
  # STRATA_PORTABLE=ON (upstream's own default, and what the released encoder
  # is built with) even though we build on the machine that runs it: the
  # alternative here, STRATA_PORTABLE=OFF, asks ggml for `-march=native`, and
  # stdenv's cc wrapper silently DROPS that flag ("Skipping impure flag
  # -march=native because NIX_ENFORCE_NO_NATIVE is set", ~40 times in the log)
  # — so the "native" build silently comes out as baseline x86-64 with no AVX2
  # at all, which measured 80 s to encode one 768-token picture on the 5950X
  # instead of seconds. Portable forces GGML_AVX2/AVX_FMA/F16C ON per translation
  # unit and keeps AVX-512 off, which is exactly the "AVX2 (as released)" row of
  # docs/DETAILS.md's own benchmark table, and it stays reproducible.
  postBuild = ''
    cmake -S ${finalAttrs.src}/tools/vision -B build-vision \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX \
      -DLLAMA_DIR=${llama} \
      -DSTRATA_VISION_CUDA=OFF \
      -DSTRATA_PORTABLE=ON
    cmake --build build-vision --target strata-vision --parallel $NIX_BUILD_CORES
  '';

  # Upstream has no install() rules for `strata`; install the binary and the
  # Python serve layer by hand. `strata-server` is what systemd runs
  # (`python -m serve.server`); the model pack / GGUF / MTP runtime stay
  # outside the store and are named by --config.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/strata
    install -Dm755 strata $out/bin/strata
    install -Dm755 build-vision/bin/strata-vision $out/bin/strata-vision
    # 0.2.0 split the repo into app/Terminal/engine, and serve/server.py now imports the
    # Terminal's Python packages at module scope (`from strata_control import engine_component,
    # hipblaslt_tuning, vision_reader, draft_layer, user_args`, and strata_control reaches
    # strata_cli) - so they install WITH the engine or `python -m serve.server` dies with
    # ModuleNotFoundError.  Both are stdlib-only on that path (textual/requests/tqdm are
    # monitor/Terminal-only and stay out); strata_tokenizer is tools/strata_tokenizer.py,
    # reachable via server.py's own `sys.path.insert(0, ROOT/"tools")`.  Verified:
    # `import serve.server` succeeds against exactly these five dirs + serverPython.
    cp -r ${finalAttrs.src}/serve ${finalAttrs.src}/tools ${finalAttrs.src}/data ${finalAttrs.src}/strata_control ${finalAttrs.src}/strata_cli $out/share/strata/

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
