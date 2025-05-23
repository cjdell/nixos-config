{ config, pkgs, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # sudo ddcutil detect --verbose
  # sudo ddcutil getvcp known
  # sudo ddcutil setvcp 100 50 --display 1
  boot.extraModulePackages = [ config.boot.kernelPackages.ddcci-driver ];
  boot.kernelModules = [ "i2c-dev" "ddcci_backlight" ];

  networking.firewall.enable = false;

  security.sudo.wheelNeedsPassword = false;

  # Set your time zone.
  time.timeZone = "Europe/London";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_GB.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_GB.UTF-8";
    LC_IDENTIFICATION = "en_GB.UTF-8";
    LC_MEASUREMENT = "en_GB.UTF-8";
    LC_MONETARY = "en_GB.UTF-8";
    LC_NAME = "en_GB.UTF-8";
    LC_NUMERIC = "en_GB.UTF-8";
    LC_PAPER = "en_GB.UTF-8";
    LC_TELEPHONE = "en_GB.UTF-8";
    LC_TIME = "en_GB.UTF-8";
  };

  # Configure console keymap
  console.keyMap = "uk";

  environment.systemPackages = with pkgs; [
    dmidecode
    git
    nmap
    inetutils
    nixfmt-rfc-style
    wget
    tmux
    screen
    efibootmgr
    unzip
    direnv
    x264
    pciutils
    usbutils
    lsof
    speedtest-rs
    tio
    dig
    lm_sensors
    stress-ng
    iotop
    p7zip
    rar
    ethtool

    # GPU Related Stuff
    intel-gpu-tools
    radeontop
    amdgpu_top
    glxinfo
    clinfo
    vulkan-tools
    vdpauinfo
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?
}
