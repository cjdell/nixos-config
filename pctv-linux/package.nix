# Userspace PCTV 320cx live stack: `pctv_probe` (libusb driver) +
# `pctv-monitor` (SDL2 live/capture GUI).  No kernel module involved; the GUI
# spawns the probe, which does the bridge/decoder bring-up and streams raw
# BT.656 on stdout.  The GUI deframes that into UYVY and pipes it to ffmpeg for
# MPEG-2 capture, and records the audio from ALSA (the card's own audio-over-USB
# path is still undecoded - see TRUTH.md 9.6).
#
#   pkgs.callPackage ./pctv-linux/package.nix { }
#   pkgs.callPackage ./pctv-linux/package.nix { noSudo = true; }
#
# `noSudo` bakes in PCTV_NO_SUDO=1 so the monitor opens the USB device as the
# invoking user (needs the udev rule from live-module.nix and no kernel driver
# bound).  Without it the probe is launched through `sudo -n`.
#
# `ffmpeg` is only needed at capture time; it is put on the wrapper's PATH (and
# in PCTV_FFMPEG) so the GUI finds it without the user installing anything.
#
# The decoder/bridge firmware are taken uncompressed from
# libreelec-dvb-firmware (the variant proven on the hardware); the NixOS
# `*.fw.zst` files cannot be read by a userspace downloader.
{ lib
, stdenv
, pkg-config
, makeWrapper
, libusb1
, SDL2
, alsa-lib
, ffmpeg
, libreelec-dvb-firmware
, noSudo ? false
}:

stdenv.mkDerivation {
  pname = "pctv-live";
  version = "0.1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./probe.c ./pctv-monitor.c ./font5x7.h ];
  };

  nativeBuildInputs = [ pkg-config makeWrapper ];
  buildInputs = [ libusb1 SDL2 alsa-lib ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -o pctv_probe probe.c $(pkg-config --cflags --libs libusb-1.0)
    $CC -O2 -Wall -o pctv-monitor pctv-monitor.c \
      $(pkg-config --cflags --libs sdl2 alsa) -lm -lpthread
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 pctv_probe "$out/bin/pctv_probe"
    install -Dm755 pctv-monitor "$out/bin/pctv-monitor"

    # Wrap the probe as well, not just the GUI.  Without this the firmware
    # paths only live in pctv-monitor's environment, and the default GUI path
    # launches the probe through `sudo -n`, whose env_reset drops every
    # PCTV_* variable: probe.c then falls back to a relative
    # "firmware/dvb-usb-dib0700-1.20.fw" and fails with "open fw: No such
    # file or directory", leaving the bridge cold (all Pipe errors after).
    # Wrapping pctv_probe means `sudo -n <wrapper>` re-establishes the paths.
    wrapProgram "$out/bin/pctv_probe" \
      --set PCTV_DECODER_FW "${libreelec-dvb-firmware}/lib/firmware/v4l-cx25840.fw" \
      --set PCTV_BRIDGE_FW "${libreelec-dvb-firmware}/lib/firmware/dvb-usb-dib0700-1.20.fw" \
      ${lib.optionalString noSudo "--set PCTV_NO_SUDO 1"}

    wrapProgram "$out/bin/pctv-monitor" \
      --set PCTV_PROBE "$out/bin/pctv_probe" \
      --set PCTV_DECODER_FW "${libreelec-dvb-firmware}/lib/firmware/v4l-cx25840.fw" \
      --set PCTV_BRIDGE_FW "${libreelec-dvb-firmware}/lib/firmware/dvb-usb-dib0700-1.20.fw" \
      --set PCTV_FFMPEG "${ffmpeg}/bin/ffmpeg" \
      --prefix PATH : "${lib.makeBinPath [ ffmpeg ]}" \
      ${lib.optionalString noSudo "--set PCTV_NO_SUDO 1"}

    runHook postInstall
  '';

  meta = {
    description = "Userspace live monitor + driver for the Pinnacle PCTV 320cx analog inputs";
    longDescription = ''
      libusb bring-up of the DiB0700 bridge and CX25843 decoder, continuous
      BT.656 capture, and an SDL2 viewer that captures MPEG-2 (720x576
      interlaced mpeg2video + MP2) from the composite/S-Video inputs plus a
      selectable ALSA audio input with a live level meter.  The V4L2
      kernel-module route is not used.
    '';
    homepage = "https://github.com/cjdell/nixos-config/tree/master/pctv-linux";
    license = lib.licenses.gpl2;
    platforms = [ "x86_64-linux" ];
    mainProgram = "pctv-monitor";
  };
}
