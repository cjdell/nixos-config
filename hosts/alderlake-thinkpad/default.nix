{ ... }:

[
  ../../common/gnome.nix
  ../../common/podman.nix
  ../../common/printer.nix
  ../../common/system.nix
  ../../users/cjdell

  ({ lib, pkgs, ... }: {
    imports = [
      ./ai.nix
      ./hardware-configuration.nix
    ];

    services.fprintd.enable = true;

    services.displayManager.autoLogin.enable = lib.mkForce false;

    services.udev.packages = [
      pkgs.platformio-core
      pkgs.openocd
    ];

    # USB access stuff
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}="1a86", ATTR{idProduct}=="8010", GROUP="plugdev"
      SUBSYSTEM=="usb", ATTR{idVendor}="4348", ATTR{idProduct}=="55e0", GROUP="plugdev"
      SUBSYSTEM=="usb", ATTR{idVendor}="1a86", ATTR{idProduct}=="8012", GROUP="plugdev"
    '';
    users.groups.plugdev.members = [ "cjdell" ];
    users.groups.plugdev = { };

    environment.systemPackages = with pkgs; [
      binutils
      gnumake
      clang

      rustup
      cargo-binutils
      gcc
      probe-rs-tools
      wlink

      nodejs
    ];

    programs.steam.enable = true;

    # programs.zed-editor = {
    #   enable = true;
    #   load_direnv = "shell_hook";
    # };
  })
]
