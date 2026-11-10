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
  # exact revision; setup.py downloads the same zip. Since 0.2.13 the ENGINE no
  # longer needs it (its ggml is vendored at the same pin - see the src comment
  # and cmakeFlags), so this fetch is now only `tools/vision`'s: that project
  # does add_subdirectory(${LLAMA_DIR} llama) and builds mtmd + llama, which the
  # vendored ggml subset cannot provide. Keep the rev equal to setup.py's
  # LLAMA_CPP_COMMIT (setup.py:240, still 3cf03257 on 0.2.13.1).
  llama = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
    hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
  };

  # serve/server.py needs jinja2 (chat template) and regex (tokenizer);
  # pillow (WebP image parts) and psutil (Monitor) are optional; numpy is
  # only used by the one-time pack tools, bundled for convenience.  0.2.12/0.2.13
  # add NO required import either (re-checked against the 0.2.13.1 tree): the new
  # module-scope imports in serve/server.py are all internal - serve.ready,
  # serve.owner_guard, serve.launch_identity, serve.logit_bias, serve.lifeline,
  # serve.responses, serve.images, strata_control.drafting, strata_control.vram_fit,
  # strata_control.gpu_roles - and every one of those files imports only stdlib
  # (checked line by line).  serve/frontend.py's jinja2 pair stays the only
  # third-party module-scope import; jsonschema/referencing stay a lazy optional
  # import in serve/structured.py (absent -> "one JSON object" only; the live
  # /v1/status reports json_schema anyway - serve has its own validator), and
  # textual/rich/requests/tqdm stay Terminal/monitor-only (strata_control.intel_app,
  # new in 0.2.13.1, is app-setup code the serve layer never imports).
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
  version = "0.2.13.1";

  # v0.2.13.1 (2026-11-09, rev 628f7495) - the current release. Engine 0.1.59.1 (CMakeLists.txt:13 - the release
  # manifest still names its engine packages 0.1.59), app/Terminal 0.2.13, Control 0.1.59.1; the .1 is a
  # Control-only hotfix (Intel Arc app setup, READMEs, the release-manifest test): v0.2.13 -> v0.2.13.1 is 7 commits
  # and its only build-relevant line is the project() version bump - the diff touches apps/, README.*, docs/,
  # packaging/, setup.py's Arc branch, strata_control/intel_app.py and tools/strata_mcp.py, none of which the engine
  # or serve layer imports on this host. Follows 0.2.12/146df3c4 (2026-11-07, engine 0.1.58) and 0.2.11/c3b3f503.
  #
  # 0.2.11 -> 0.2.13.1 (checked against the trees, not the changelog; only what this build touches):
  #   * THE AUDIT PATCH RE-BASED 2026-11-10: ZERO rejected hunks again, for the second re-base running. All 19 landed
  #     with `patch -p1 --fuzz=0`; the drift is pure context - verify.cpp +3 (two hunks +4, the run()-tail dump +10),
  #     verify.hpp +19, iq_kernels.cu hunks 2-4 +7 (hunk 1 at its own line numbers), iq_kernels.hpp / sampler.hpp /
  #     sampler.cu unmoved. Regenerated from the patched tree: 19 hunks, 280 additions, 0 deletions, added lines
  #     BYTE-IDENTICAL to the 0.2.11 file (only context and hunk headers move), `patch -p1 --fuzz=0` with NO offsets
  #     and `git apply --check` both clean on 628f7495. The #879 anchors intact: nf_mask_/note_nonfinite (verify.cpp
  #     :5232, 7 nf_mask_ uses) and hits_in_combine (:2403/:2483). The audit's own env gate survived the move:
  #     STRATA_KERNEL_AUDIT is still read in verify.cpp:1112 and iq_kernels.cu:6265.
  #   * THE ggml SOURCE MOVED INTO THE TREE, and we now take the vendored one: 0.2.13's "cleanup 5.4" splits the
  #     engine by backend (cmake/backends/{cpu,cuda,hip,...}.cmake, add_executable(strata) now
  #     cmake/strata_gpu_engine.cmake:477) and vendors the ggml it builds in third_party/strata-ggml, "so an engine
  #     build needs no llama.cpp download" (its UPSTREAM.md). VERIFIED EQUIVALENT: `diff -r` of llama.cpp 3cf03257's
  #     ggml/ against third_party/strata-ggml/ggml shows EVERY common source/header byte-identical - only
  #     ggml/CMakeLists.txt and ggml/src/CMakeLists.txt differ (backends, tests, install rules trimmed) plus Strata's
  #     own ggml/src/ggml-cuda-tq/ trellis folder, and the pin in third_party/ggml/VERSION.txt is exactly 3cf03257.
  #     So the `-DSTRATA_GGML_DIR=${llama}` flag is dropped: the compiled ggml is the same bytes as our previous
  #     builds, and this is how upstream builds its own release engines (the ones its R9700 numbers come from). The
  #     override is still honoured ("an override kept for two releases, then removed"), so if upstream removes it
  #     before we bump again, nothing here needs doing - we already build from the vendored tree. The `llama` fetch
  #     above stays regardless: tools/vision does add_subdirectory(${LLAMA_DIR} llama) and needs the full checkout.
  #     Both paths enable the trellis MMQ types the same way (the vendored ggml-cuda-tq, or an overlay of a pinned
  #     llama.cpp): STRATA_MMQ_TQ_OVERLAY is ON by default, and our IQ4_XS pack reads none of those types.
  #   * postPatch clamps: both targets still UNIQUE, still unclamped, both still live because we run --kv int8.
  #     kv_q8.cu's `const uint16_t sbits = f16_from_f32(amax / 127.0f);` is STILL at :55 (and the file still has no
  #     "65504" anywhere); prefill/kernels.cu's `const uint16_t sb = hf(amax / 127.0f);` is still exactly once but now
  #     at :2558 (was 2509 on 0.2.11, 2257 in 0.2.7.1), hf_sat still defined above it (:69). Both --replace-fail
  #     targets re-checked on 628f7495.
  #   * serve/server.py: the installPhase rewrite targets MOVED but are byte-identical and still exactly once each -
  #     died_note(e) is defined at :436 and rewritten at :8633, the ValueError ("# headers are sent, so no 400 now")
  #     at :8645. Upstream's #1892 guard is intact, the engine launch is unchanged: popen([exe, "--serve", *args]) at
  #     :1209. The serve layer gained serve/{ready,owner_guard,launch_identity,logit_bias,lifeline,responses,images}.py
  #     and strata_control/{drafting,vram_fit,gpu_roles}.py imports at module scope - all stdlib-only, all optional at
  #     runtime (owner_guard only runs with --owner-fd, ready_file only with --ready-file), so our ExecStart form and
  #     every config key still work: exe/args/cwd/tokenizer/model_name/log/allowed_hosts/backend/lib_dirs/vision/env/
  #     before_load (now with #1997's before_load_timeout_s / _ignore_failure / _strict siblings, which we do not set)
  #     and the --engine/--config/--host/--port CLI; /v1/status, /v1/unload, /health and /slots - what ./gpu-mode.sh
  #     drives - are all still served (:8126, :8203). Every one of our 18 engine args is still parsed (grep of
  #     src/program + src/core), as are the drafting layer's --draft/--draft-model/--draft-fallback/--draft-conf/
  #     --mtp-draft-vocab.
  #   * DFlash2 (./strata.nix sets "drafting": "dflash2", so this is the drafter we run) does NOT move on 0.2.12/13 -
  #     but upstream now considers our card a problem. Details in the drafting comment in ./strata.nix: the pack pins
  #     are byte-identical (selq4 339,694,592 B / sha 4a42b982..., REPO+REVISION unchanged, no re-download), the
  #     _SUPPORTED_NAME regex is unchanged (our -unsloth-ud-iq4-xs-v31 name still passes), --spec stays 6 (WIDE_WINDOW
  #     8 is gfx1151 and big-Blackwell only, drafting.py:778), and Strata's NEW tuned drafter deliberately does NOT
  #     apply here: SET_DEFAULTS ("hip","unsloth-ud-iq4_xs-v31") is tuned=true but gated where="gfx1151", and
  #     tuned_applies() returns arch == "gfx1151" - our gfx1201 keeps the stock selq4 pack pack_path() picks today.
  #   * Python surface: see the serverPython comment above - no changes needed.
  #   * gfx12/R9700 BEHAVIOUR CHANGES to EXPECT (fuller comments in ./strata.nix's env section): NEW in 0.2.12, on by
  #     default, and it reaches our traffic - the CHUNKED GDN SCAN. In 0.2.12 it was the launcher's rule and fired for
  #     prompt chunks of 30,000+ tokens (upstream on an R9700: 32K +6.1 %, 64K +6.7 %); 0.2.13 made it the engine's own
  #     default and stronger - generate.cpp:3821-3830 calls apply_gdn_chunked_default(true, all_gfx12) "Linux, every
  #     visible card gfx12: the chunked GDN scan FROM THE FIRST CHUNK (was the launcher's GDN_STACK_GFX12)", so here
  #     (one gfx12 card) every prompt chunk takes it, not only the 30K+ ones. Two consequences for anyone verifying
  #     this: the engine sets it with setenv(..., replace=0) IN-PROCESS before apply_arch_defaults runs, so (a) the
  #     "prompt chunks of 30,000+ tokens use the chunked GDN scan" line is deliberately NOT printed (upstream says so
  #     in that block's own comment), and (b) /proc/<engine>/environ does NOT show it either - setenv after exec is
  #     invisible there. Confirm by A/B (env.STRATA_GDN_CHUNKED = "0") or by the speed, not by the log line.
  #     It is a different kernel, so answers CAN differ in the last digits at the depths
  #     our agent traffic lives at - and STRATA_SELECT_WMMA (the matrix-core QSA scorer past 28,672 tokens, KL 0.002)
  #     was already on for us in 0.2.11 (its banner DOES print: "the matrix-core QSA block scorer is on once a prompt
  #     is past 28,672 tokens"). 0.2.12's other R9700 headline is 32K prompts +8.6..11.6 %.
  #     The 0.2.13 hipBLASLt change (the packaged tuning table is no longer used by default on gfx1201/gfx1100, which
  #     "restores the 10-19 rule of gfx1151 only" - gemm.cu:319 `if (!table_forced && arch != "gfx1151") return
  #     nullptr`) is a NO-OP here: it reads like it moves our card, but our build has never shipped a `tuning/` folder
  #     beside the binary (own_tuning_dir() finds nothing on 0.2.11 either), so we have always run plain hipBLAS.
  #   * NEW AND OPEN, and it is about our drafter: "Radeon gfx1201: DFlash2 chosen by hand can stall on the prompt
  #     (11 of 50 engines on 0.2.11). The engine stops itself and the next request restarts it" - still listed as
  #     unfixed in 0.2.13 ("not looked at again"), upstream's fix (PE-RDNA4) pending. drafting.py's AUTO_MTP
  #     {("hip","gfx1201")} makes Auto pick MTP on this card, and says a saved "drafting": "dflash2" - us - still
  #     starts DFlash2. We keep it (measured +2-2.5 % decode over MTP, 95-98 % cache hits live, 6 days without a
  #     stall); the one-line revert is "drafting": "mtp", which is what Auto would now choose for us.
  #     KNOWN still open and ours: #5153 - a DFlash2-only run can fail to restore a parked conversation ("conversation
  #     snapshot: invalid K/V extent"); the turn survives, the next request re-reads the prompt. grep strata.log for it
  #     if parked-conversation reuse drops.
  #   * Linux-only fix we benefit from: #5327 (PR #5531) - an expert-store shortfall that the file cache can cover now
  #     loads through the file cache instead of failing. With --resident-budget-gib 56 on 94 GB that is the difference
  #     between a slow start and no start; watch for "expert reads now go through the file cache" in strata.log.
  #   * NOT APPLICABLE HERE (checked so nobody re-reads the changelog): the tuned drafter's other cells (Metal, CUDA
  #     resident, Strix Halo gfx1151, Arc SYCL - where tuned_applies gates on arch), Auto-on-gfx1201's MTP (we name
  #     dflash2), the 12 GB file-tier rules and STRATA_FILE_TIER_HONEST, Strix Halo's 2,560 MiB Windows floor and
  #     reserve, the app's Load fetching a drafter, the Qwen4 feed groundwork (strata --geometry, per-shape engines),
  #     the app-start/3.12 MB bundle work, removed switches (STRATA_METAL_*, STRATA_MMVQ_PF/_SG, STRATA_GR_Q32_PL,
  #     STRATA_DF2_GATE, STRATA_DF2_ROW_MS - none of them ours; our env is HIP_VISIBLE_DEVICES + STRATA_KERNEL_AUDIT +
  #     HSA_USERPTR_FOR_PAGED_MEM), Intel Arc oneMKL determinism, the DGX Spark, Mac/Metal, every Windows/app/Terminal
  #     fix, and the still-unrelated Flash-Next batching (we stay at one slot - docs/strata-batching.md).
  #   * Opt-in, deliberately NOT set, and it is written for our exact pack: STRATA_PF_FUSED_Q50=1 (moe_fused_iq.cu
  #     :1940-1955: "Q5_0 down (UD-IQ4_XS-v31: 33 of 48 layers...)" - gfx12 keeps its int8 fused kernel only with the
  #     switch, upstream measures R9700 prompts 2K +44 %, 8K +40 %) and it "changes the arithmetic of those layers",
  #     so it needs an A/B here before it goes into ./strata.nix's env.
  #
  # 0.2.10 -> 0.2.11 (checked against the trees, not the changelog; only what this build touches):
  #   * The pinned llama.cpp is UNCHANGED: setup.py:240 LLAMA_CPP_COMMIT is still 3cf03257, so our `llama`
  #     fetch and every ggml hash move not at all.
  #   * THE AUDIT PATCH RE-BASED 2026-11-05: ZERO rejected hunks, for the first re-base in this file's
  #     history. All 19 landed with `patch -p1 --fuzz=0`; four in iq_kernels.cu carried a +3-line offset,
  #     everything else applied at its own line numbers. Regenerated from the patched tree: 19 hunks, 280
  #     additions, 0 deletions, added lines BYTE-IDENTICAL to the 0.2.10 file (only context and hunk
  #     headers moved), `patch -p1 --fuzz=0` with NO offsets and `git apply --check` both clean on
  #     c3b3f503. The #879 anchors intact: nf_mask_/note_nonfinite (11 lines in verify.cpp) and
  #     hits_in_combine. 0.2.11's touches to the audited files are the sfnx split-engine work and the
  #     DFlash2 batch drafters - not our single-card IQ4_XS kernels.
  #   * postPatch clamps: kv_q8.cu's target is still UNIQUE and still unclamped, still at :55 (zero "65504"
  #     in the file); prefill/kernels.cu's is still exactly once and still unclamped, STILL at :2509 (the
  #     0.2.10 line), hf_sat still defined above it (now :65). Both --replace-fail targets re-checked on
  #     c3b3f503.
  #   * serve/server.py: the installPhase rewrite targets MOVED - the mid-stream EngineDied message is now
  #     built by died_note(e) (server.py:437, used by `err = ...died_note(e)` at :8658; the EngineDied 503
  #     paths also call it but were never rewritten), so the first substituteInPlace below rewrites the
  #     died_note call and prefixes "server error: " to its result. The ValueError target ("# headers are
  #     sent, so no 400 now") is untouched at :8670. Upstream's #1892 guard is intact: all 17 non-finite/
  #     retry lines still present. The engine launch is unchanged: popen([exe, "--serve", *args]).
  #   * DFlash2 is LIVE as our drafter since 2026-11-04 ("drafting": "dflash2", see ./strata.nix) and
  #     0.2.11 does not move our path: _SUPPORTED_NAME regex identical (qwen3.8-flash-next-unsloth-ud-iq4-xs
  #     still passes, re-checked against the regex), SPEC_WINDOW 6 / DRAFT_CONF 0.35, drafting_fetch.py's
  #     pinned bytes/sha/URLs unchanged so /home/cjdell/Strata/dflash2/'s selq4 pack is reused (no
  #     re-download), and apply() shapes exactly the same flags (strips --mtp/--spec-min-p/our --spec, adds
  #     --draft dflash2 --draft-model <pack> --draft-fallback none --spec 6 --draft-conf by-VRAM).
  #   * Python surface: see the serverPython comment above - no changes needed.
  #   * Build surface unchanged in every way the installPhase assumes: no install() rules; add_executable
  #     (strata src/program/generate.cpp) now at CMakeLists.txt:898; STRATA_GGML_DIR still a CACHE PATH
  #     (:2062); every cmake flag we pass is still an option; tools/vision still builds strata-vision with
  #     the same LLAMA_DIR/STRATA_VISION_CUDA/STRATA_PORTABLE flags and the SVE1 record format lives in the
  #     same two files; serve/ tools/ data/ strata_control/ strata_cli/ all still exist; iq_pack.py
  #     --compat-bf16, expert-profile.bin, draft_vocab.bin, mtp_fetch/mtp_pack/mtp_rt all still there; all
  #     18+ engine args ./strata.nix passes are still parsed by generate.cpp; so are every config key
  #     (exe args drafting cwd tokenizer model_name log allowed_hosts backend lib_dirs vision env
  #     before_load) and the --engine/--config/--host/--port CLI.
  #   * gfx12/R9700 BEHAVIOUR CHANGES to EXPECT (from the release's "Behaviour that changed"; the full
  #     comments are in ./strata.nix's env section): `--prefill auto` now tops out at a 32768-token chunk
  #     (was 16384 since 0.1.44; RAM guard steps 32768->16384->8192; revert STRATA_GFX12_CHUNK=16/=0), the
  #     prompt staging ring grows to 256/192 slots from 96 (bit-identical logits in upstream's test;
  #     revert STRATA_GFX12_RING=0), and the K-quant prompt kernels turn on on gfx12 - for UD-Q4/Q5/Q6_K_XL
  #     files; our pack is IQ4_XS, whose MMQ prompt path was already built in. Setup writing
  #     STRATA_ROUTE_TAIL_SKIP=0 for Unsloth files is gone - never applied to us (our config is Nix-made and
  #     the skip has been the engine default here since 0.1.43 at our 43 % expert cache). A VRAM-short
  #     start with our named DFlash2 is now retried once with NO drafter (new SHORT_OF_VRAM reason, never
  #     silently with MTP) - relevant at 232 MiB free; watch for "short of memory" in strata.log.
  #   * NOT APPLICABLE HERE (checked so nobody re-reads the changelog): Unsloth's new v3.1 GGUF sets
  #     (UD-IQ4_XS-v31 is a DIFFERENT set from our pack; ours keeps running untouched) and their new Q5_0
  #     expert format; the 4x-R9700 all-cards split engine Auto pick (one card; our serve + --config path
  #     stays out of its way); named-DFlash2 per-request drafters with --batch (one slot here); NVIDIA
  #     K-quant kernels + 32768 chunk + FP16 weight cache; the PCIe CPU-pool follow-up rule (CUDA layer
  #     splits and single NVIDIA cards - "HIP layer splits keep the old rule"); short-card layer-split
  #     trim/walk; app chat-file storage and every Windows/app/Terminal fix; the DGX Spark.
  #   * FIXED on the serve layer, free win: #2892, a reply going to the wrong request between model
  #     replicas (Python-only; we run one slot). KNOWN, affects us, watch: #5153 - with a DFlash2-only run
  #     (us since 2026-11-04, and this predates 0.2.11) saving/restoring a parked conversation can fail
  #     "conversation snapshot: invalid K/V extent"; the turn survives, the next request just re-reads the
  #     prompt. grep /var/lib/strata/strata.log for it if parked-conversation reuse ever drops.
  #
  # 0.2.1.1 -> 0.2.7.1 (checked against the trees, not the changelog; only what this build touches):
  #   * THE AUDIT PATCH IS STILL THE ONLY NON-UPSTREAM CODE, AND #879 IS NOT DEAD (the 2026-10-19 repro on
  #     0.1.45 stands: IQ4_XS gate/up, MMQ prompt path, layer 1).  Re-based onto 46c152a1 on 2026-10-29:
  #     19 hunks, 280 additions, 0 deletions, added lines BYTE-IDENTICAL to the 0.2.1.1 file, `patch -p1
  #     --fuzz=0` with NO offsets and `git apply --check` both clean (regenerated from the patched tree).
  #     Thirteen hunks only moved (verify.cpp +184..+244, iq_kernels.cu +1478..+1506, sampler.cu +42,
  #     iq_kernels.hpp +7); six were re-placed by hand, every one a pure context shift:
  #       - verify.hpp: a new `topk_scratch_` member sits between `sel_` and `logits_` (the audit lines go
  #         between `logits_` and `ids_` exactly as before).
  #       - verify.cpp shared-expert site: `if (sh_fork)` grew a body (`note_prio_tail(sh_cs_, -1);`).
  #       - the grouped/hit_out site: `grouped()` grew a trailing `true`, and upstream added an `ar_on()`
  #         branch that computes hits straight into parts_out - ar_on() is `all_resident_ && !ar_off_`
  #         (verify.hpp:528), NEVER live on this card (43 % expert-cache hits), so the audit is NOT mirrored
  #         there; the audited branch is still the one that runs.
  #       - the stamp(l, 24) site: the new tap_on_/STRATA_TAP_FILE block sits right after it.
  #       - the run() tail dump: `tap_write` + STRATA_LOGITS_DUMP now sit between `note_nonfinite(T,
  #         nullptr);` and STRATA_DBG_NAN; the dump goes right after note_nonfinite in Verifier::run (:3095)
  #         - the second note_nonfinite call, in Verifier::pl_finish, is NOT the audit site.
  #       - iq_kernels.cu gu site: upstream inserted `if (g_exp_phase == 3) return;` (the bench) right after
  #         check("native_expert_grouped/gu"), and the gu launch grew nibble/expdec branches; the stage_audit
  #         pair is kept BEFORE the early return, so even a gate/up-only bench is audited.
  #     The guard it rides on is untouched: server.py still holds all 17 non-finite/retry lines
  #     (EngineNonFinite, nf_retried), logits_nonfinite_rows is still in verify.cpp (:2498), and
  #     note_nonfinite/hits_in_combine still anchor the audit hunks.
  #   * THE GUARD IS STILL UPSTREAM'S (#1892, on by default, STRATA_NAN_GUARD=0 off): the poisoned window
  #     emits nothing, every cached state is dropped so the next request re-reads the prompt from token 0,
  #     and serve/server.py retries once.  Our own guard was removed in 0.1.43; do not add it back.
  #   * THE TWO q8_1/int8 CLAMPS ARE STILL OURS AND STILL UNCLAMPED UPSTREAM: kv_q8.cu's append
  #     `const uint16_t sbits = f16_from_f32(amax / 127.0f);` is still at :55 and still unique;
  #     prefill/kernels.cu's clamp (3) target `const uint16_t sb = hf(amax / 127.0f);` is still exactly
  #     once, now at :2257 (was 2199 on 0.2.1.1, 1702 in 0.1.44.1), and hf_sat is still defined, at :64.
  #     Both still live because we run --kv int8; both --replace-fail targets are UNIQUE (checked on
  #     46c152a1).
  #   * serve/server.py: BOTH installPhase rewrite targets are still present exactly once (now 7664 and
  #     7676, was 6743/6755), so the "server error" prefix that makes our remaining hard errors retryable
  #     by Pi still applies.  The engine launch is unchanged: popen([exe, "--serve", *args]), and a config
  #     "vision" section still adds --vision (#1322) with --vram-reserve-mib only for a GPU reader.
  #   * Build surface unchanged: no install() rules (installPhase still hand-installs), the binary is still
  #     add_executable(strata src/program/generate.cpp) (CMakeLists.txt:843, was 735), every cmake flag we
  #     pass is still an option, STRATA_GGML_DIR is still a CACHE PATH (:1839), serve/ + tools/ + data/
  #     still exist (expert-profile.bin, draft_vocab.bin, iq_pack.py --compat-bf16, mtp_fetch/mtp_pack/
  #     mtp_rt all still there), tools/vision still builds strata-vision with LLAMA_DIR /
  #     STRATA_VISION_CUDA / STRATA_PORTABLE (STRATA_VISION_HIP exists but builds a SEPARATE opt-in program
  #     named strata-vision-hip - we keep the CPU encoder, see the vision comment in ./strata.nix), and all
  #     18 engine args ./strata.nix passes are still parsed (checked against generate.cpp).  The ggml pin
  #     is UNCHANGED (setup.py:222 LLAMA_CPP_COMMIT = 3cf03257..., same rev since 0.1.41), so the `llama`
  #     fetch above stays exactly as it was.
  #   * Python surface unchanged: the five strata_control modules server.py imports at module scope
  #     (engine_component, hipblaslt_tuning, vision_reader, draft_layer, user_args, plus their
  #     strata_control deps acquisition/longpath/targets) are stdlib-only; rich/textual live only in
  #     strata_cli/dashboard.py + monitor.py (Terminal-only, never imported by serve), certifi/truststore
  #     only in function bodies of strata_control/tls.py, and jsonschema/referencing stay lazy+optional in
  #     serve/structured.py (absent -> "one JSON object" checking only).  serverPython needs no changes.
  #   * AMD/gfx12 behaviour changes to EXPECT (these MOVE answers or speed on OUR exact card):
  #       - 0.2.7 "Radeon RX 9000 and AI PRO R9700: faster Qwen", ON by default (the app's "Faster answers
  #         on Radeon RX 9000" switch turns it off): the per-token lookup table stays in RAM when the PC has
  #         room and the decode split between card and CPU starts differently - upstream says answers CAN
  #         DIFFER IN WORDING (30 test tasks passed in every arm, no invented facts).
  #       - 0.2.6/0.2.7 re-froze STRATA_DEFAULTS=026 for Qwen (gfx12 decode switches, wide/split
  #         hyper-connection reads, int8 prompt attention, PLE residency policy), so the 0.1.43/0.1.44 A/B
  #         notes in ./strata.nix no longer describe every default by name.
  #       - 0.2.5: the RAM expert store is no longer capped at 48 GB - it can now hold EVERY routed expert
  #         (it copies the whole table where free RAM holds it).  On this box watch RAM during the load (the
  #         -cram OOM history, AGENTS.md "RAM" bullet); the zram cushion stays mandatory.  Same release:
  #         fewer GPU launches per layer (R9700 +2.4 % decode), the prompt path is chosen by prompt LENGTH
  #         alone (deterministic, replaces a timing guess that changed answers), and one card in a multi-
  #         card PC no longer gets 1024-token prompt chunks (not our case).
  #       - 0.2.2+: a GPU that went through resets can hang engine starts until reboot (seen on a 4 x R9700
  #         box) - relevant to our MES-reset history (docs/strata-hang.md), nothing to configure.
  #   * NOT APPLICABLE HERE (checked so nobody re-reads the changelog): DeepSeek-V4.1-Flash - the whole new
  #     model family, its own engine packages, gfx1151/Strix Halo, huge pages, DSpark, --split-serve - the
  #     app/Terminal/Control/Docker layer, NVFP4, Qwen3.6-35B-A3B, Mac/Metal, Windows/WSL, Intel Arc, RDNA4
  #     multi-GPU pipelining (one card here), Flash-Next --parallel batching (we stay at one slot -
  #     docs/strata-batching.md), and every opt-in STRATA_SLOT_* / STRATA_* switch from 0.2.2-0.2.7.
  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "628f74955a56fcba092495b800dd02af75373a0f";
    hash = "sha256-nQ3Jdui9y6r5FqsEoJraKsqBLeCTRRERU0zS8CQTqSY=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
    makeWrapper
  ];

  # The default rocmPackages scope (all gfx targets, incl. gfx1201) so those
  # derivations hit the binary cache; our own code is compiled for gfx1201 alone
  # below. Build-time only: the version nixpkgs carries moves (7.2.3 -> 7.2.4
  # between the 0.2.11 and 0.2.13.1 deploys) and does not matter at runtime - the
  # engine maps libamdhip64/rocblas/hipblaslt from ./rocm10-runtime.nix via
  # lib_dirs, and `cat /proc/<engine>/maps | grep -c rocm10-runtime` is the proof
  # (118 mapped files today, 0 from nixpkgs' ROCm).
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
    # No -DSTRATA_GGML_DIR since 0.2.13: the engine builds the ggml vendored in
    # third_party/strata-ggml, which `diff -r` proves byte-identical to our
    # pinned llama.cpp's ggml at every common file (see the src comment). The
    # override still worked on 0.2.13.1 but upstream removes it "after two
    # releases", and the vendored tree is the path its own release engines build
    # from - so we take it and keep `llama` only for tools/vision below.
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
  # 7c9399d982d98229c61fcefaaa0b9215), re-based onto our exact pin 628f7495 (v0.2.13.1) on
  # 2026-11-10: zero rejections for the second time - all 19 hunks apply with --fuzz=0 (verify.cpp
  # with a +3/+4/+10 offset, verify.hpp +19, three of iq_kernels.cu's four at +7, the rest at their own
  # line numbers), landing in
  # Verifier::init/record_window/run and inside native_expert_grouped - the #879 suspect site,
  # still untouched upstream: iq_kernels.cu changed by 7 lines between 0.2.11 and 0.2.13.1, all of them the
  # STRATA_EXPERT_V2K block at :6306-6326 (it gains Windows gfx1151; gfx12's default and its bits are unchanged),
  # which is why hunks 2-4 moved +7 and hunk 1 did not.  The added lines are
  # byte-identical to the 0.2.11 file.  Regenerated
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
  # STATUS ON 0.2.13.1 (checked against the tree, not the changelog): neither clamp site moved into a clamp -
  # kv_q8.cu's int8 append is still unclamped at :55 (still unique, and the file contains no "65504" at
  # all), and prefill/kernels.cu's clamp (3) target is still unclamped and now at :2558 -
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
  #     (kv_append_kernel, prefill/kernels.cu:2558 - it moved from 2509 in 0.2.11, 2257 in 0.2.7.1, 2199 in 0.2.1.1,
  #     1702 in
  #     0.1.44.1, 1691 in 0.1.43 and 1340 in 0.1.42; hf_sat is still defined
  #     above it, now at :69) -
  #     never covered by #606 nor by #1448, and the site our incident-2
  #     132,947-token prompt was fixed by.  Still live: we run --kv int8.  Both --replace-fail
  #     targets are still UNIQUE in their file (checked on 628f7495).
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
  # (`build_vision_cpu`, setup.py:5333 on 0.2.13.1): CUDA OFF, and the same Release build
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
    # 0.2.11 moved the EngineDied mid-stream message into died_note(e)
    # (server.py:437 on 0.2.11, still :436 on 0.2.13.1); the rewrite wraps its
    # result, at :8633 now (was :8658) and the ValueError at :8645. The EngineDied 503 paths
    # also call died_note but were never rewritten ("headers are sent" cases
    # are the ones the client can only read as text).
    substituteInPlace $out/share/strata/serve/server.py \
      --replace-fail \
        'err = {"error": {"type": "server_error", "message": died_note(e)}}' \
        'err = {"error": {"type": "server_error", "message": "server error: " + died_note(e)}}' \
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
