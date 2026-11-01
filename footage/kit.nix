# footage-kit — video "cleanup" toolkit for this repo's machines.
#
# A self-contained CLI over the footage-cleaning pipeline:
#   probe -> VapourSynth (QTGMC-style deinterlace + temporal denoise)
#   -> optional GPU RealESRGAN upscale / RIFE interpolation (video2x,
#   Vulkan) -> FFmpeg encode (x265 / SVT-AV1 / x264 / VAAPI).
#
# Built entirely from the fleet's pinned nixpkgs (vapoursynth + plugins,
# video2x, realesrgan-ncnn-vulkan, ffmpeg, x264/x265/svt-av1) plus two
# fixes this nixpkgs pin needs:
#
#   * vapoursynth-znedi3 fails on gcc 16: its vendored graphengine uses
#     PTRDIFF_MAX without <cstdint>. One NIX_CFLAGS_COMPILE flag.
#   * video2x 6.4.0 fails on fmt 12: std::filesystem::path::u8string()
#     returns std::u8string with gcc 14+ and fmt 12 rejects mixing
#     character types. Sed u8string() -> string() over the sources
#     (native == UTF-8 on Linux, so behaviour is unchanged).
#
# Build / run:
#   nix build .#footage-kit        # result/bin/{footage-clean,footage-probe}
#   just footage --help
#
# GPU note: video2x/ncnn talk Vulkan. On zen3-nixos the R9700 is leased
# by Strata (`gpu-mode`); footage-clean warns when the LLM is resident
# and honours `--gpu N` to pin an ncnn device (e.g. the RX 580).
# VapourSynth (deint/denoise) and x265 encoding are pure CPU.
{
  lib,
  stdenv,
  ffmpeg,
  python3,
  realesrgan-ncnn-vulkan,
  vapoursynth,
  vapoursynth-bestsource,
  vapoursynth-eedi3,
  vapoursynth-mvtools,
  vapoursynth-nnedi3cl,
  vapoursynth-znedi3,
  video2x,
}:
let
  znedi3 = vapoursynth-znedi3.overrideAttrs (
    finalAttrs: prevAttrs: {
      NIX_CFLAGS_COMPILE = (prevAttrs.NIX_CFLAGS_COMPILE or "") + " -include cstdint";
    }
  );

  video2xPatched = video2x.overrideAttrs (
    finalAttrs: prevAttrs: {
      postPatch = (prevAttrs.postPatch or "") + ''
        find . \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -type f -print0 \
          | xargs -0 sed -i 's/u8string()/string()/g'
      '';
    }
  );

  vspipeEnv = vapoursynth.withPlugins [
    vapoursynth-bestsource
    vapoursynth-mvtools
    vapoursynth-eedi3
    vapoursynth-nnedi3cl
    znedi3
  ];

  esrganPkg = lib.getBin realesrgan-ncnn-vulkan;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "footage-kit";
  version = "0.1";
  src = ./.;

  # The scripts are source data; nothing to build.
  dontBuild = true;
  dontStrip = true;
  phases = [
    "installPhase"
    "fixupPhase"
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/share/footage"
    cp "$src/clean.vsh" "$src/README.md" "$out/share/footage/"
    cp "$src/footage-clean.sh" "$out/share/footage/footage-clean.sh.in"
    cp "$src/footage-probe.sh" "$out/share/footage/footage-probe.sh.in"

    substitute "$src/footage-clean.sh" "$out/bin/footage-clean" \
      --replace-fail '@vspipe@' '${vspipeEnv}/bin/vspipe' \
      --replace-fail '@video2x@' '${video2xPatched}/bin/video2x' \
      --replace-fail '@realesrgan@' '${esrganPkg}/bin/realesrgan-ncnn-vulkan' \
      --replace-fail '@realesrganModels@' '${esrganPkg}/share/models' \
      --replace-fail '@ffmpeg@' '${ffmpeg}/bin/ffmpeg' \
      --replace-fail '@ffprobe@' '${ffmpeg}/bin/ffprobe' \
      --replace-fail '@python3@' '${python3}/bin/python3' \
      --replace-fail '@cleanvsh@' "$out/share/footage/clean.vsh"
    chmod +x "$out/bin/footage-clean"

    substitute "$src/footage-probe.sh" "$out/bin/footage-probe" \
      --replace-fail '@ffprobe@' '${ffmpeg}/bin/ffprobe' \
      --replace-fail '@ffmpeg@' '${ffmpeg}/bin/ffmpeg' \
      --replace-fail '@python3@' '${python3}/bin/python3'
    chmod +x "$out/bin/footage-probe"

    runHook postInstall
  '';

  passthru = {
    inherit znedi3 video2xPatched vspipeEnv;
  };

  meta = {
    description = "Video cleanup pipeline: VapourSynth deint+denoise, RealESRGAN/RIFE via video2x, FFmpeg encode";
    mainProgram = "footage-clean";
    platforms = [ "x86_64-linux" ];
    license = lib.licenses.mit;
  };
})
