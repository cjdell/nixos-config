{ config, pkgs, ... }:

{
  boot.binfmt.registrations.appimage = {
    wrapInterpreterInShell = false;
    interpreter = "${pkgs.appimage-run}/bin/appimage-run";
    recognitionType = "magic";
    offset = 0;
    mask = ''\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff'';
    magicOrExtension = ''\x7fELF....AI\x02'';
  };

  # Enable networking
  networking.networkmanager.enable = true;

  hardware.bluetooth.enable = true; # enables support for Bluetooth
  hardware.bluetooth.powerOnBoot = true; # powers up the default Bluetooth controller on boot

  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "gb";
    variant = "";
  };

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;
  };

  # Install firefox.
  programs.firefox.enable = true;

  programs.virt-manager.enable = true;

  programs.gnome-disks.enable = true;

  virtualisation.libvirtd.enable = true;

  virtualisation.spiceUSBRedirection.enable = true;

  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # environment.sessionVariables.POWERDEVIL_NO_DDCUTIL = "1";

  # sudo ddcutil detect --verbose
  # sudo ddcutil getvcp known
  # sudo ddcutil setvcp 100 50 --display 1
  # boot.extraModulePackages = [ config.boot.kernelPackages.ddcci-driver ];
  boot.kernelModules = [
    "i2c-dev"
    # "ddcci_backlight"
  ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    # GUI Things
    # vscode
    appimage-run
    # geekbench
    google-chrome
    kdePackages.kate
    # bottles - commented out 2026-10-09: it is an FHS env with `multiArch = true`
    # and pulls `dosbox` into its 32-bit `multiPkgs` (nixpkgs' bottles/package.nix),
    # so its closure contains i686-linux derivations. Builder-only hosts
    # (nix.settings.max-jobs = 0 + a single x86_64-linux ssh-ng builder:
    # machines/macbook-pro-2009, hosts/alderlake-thinkpad) cannot place those:
    # "Failed to find a machine for remote build! required (system, features):
    # (i686-linux, [])" -> system-path and the whole toplevel fail. To bring it
    # back on such a host, either add "i686-linux" to nix.buildMachines[].system
    # (if the builder really builds 32-bit) or re-enable local builds.
    xhost
    notify-desktop
    ddcutil
    imsprog
    zed-editor
    moonlight-qt
    remmina

    # GPU Related Stuff
    furmark
    mesa-demos

    # Tools
    ffmpeg
    mediainfo
  ];
}
