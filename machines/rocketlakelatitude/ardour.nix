{ config, lib, pkgs, ... }:

let
  NIX_LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib";
in
{
  services.pipewire.jack.enable = true;

  # LD_PRELOAD="/nix/store/yp73is8ggzwgxrhs4ps2kqqa3j0irxhf-freetype-2.13.3/lib/libfreetype.so.6:/nix/store/kkkjy6fyfmw0mclpyvjpcjf7bgq9dj96-alsa-lib-1.2.14/lib/libasound.so.2.0.0:/nix/store/xm08aqdd7pxcdhm0ak6aqb1v7hw5q6ri-gcc-14.3.0-lib/lib/libatomic.so.1" ardour8

  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      freetype
      alsa-lib
      gcc
    ];
  };

  environment.sessionVariables.VST3_PATH = "$HOME/.vst3";

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "ardour-with-plugin-support" ''
      export LD_LIBRARY_PATH=${config.services.pipewire.package.jack}/lib:${NIX_LD_LIBRARY_PATH}
      exec ${pkgs.ardour}/bin/ardour8 "$@"
    '')

    (pkgs.makeDesktopItem {
      name = "ardour-with-plugin-support";
      desktopName = "Ardour With Plugin Support";
      exec = "ardour-with-plugin-support";
      icon = "${pkgs.ardour}/share/icons/hicolor/512x512/apps/ardour8.png";
      categories = [
        "AudioVideo"
        "Audio"
      ];
    })
  ];
}
