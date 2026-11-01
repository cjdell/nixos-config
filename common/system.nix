{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sharedPackages;
in
{
  imports = [
    # The `sharedPackages.enable` switch that gates this module's package list
    # (see the option doc below and `environment.systemPackages` further down).
    # Declared as a nested module rather than as a top-level `options` here
    # because a NixOS module may not mix `options`/`config` with shorthand
    # option assignments: adding `options` on the top level would force every
    # setting in this file under a `config = { ... }` wrapper for no gain.
    (
      { lib, ... }:
      {
        options.sharedPackages.enable = lib.mkEnableOption ''
          the fleet-wide CLI toolset common/system.nix installs (git, tmux, wget,
          flashrom, smartmontools, stress-ng, cargo/rustup, deno, nixd, the GPU
          inspectors, ...). Several GB of closure. It is a convenience set and
          nothing else in this repo depends on it, so a lean box that declares
          its own short package list - machines/macbook-pro-2009, the PCTV 320cx
          capture station running common/desktop-light.nix - switches it off and
          keeps just what it uses (`git` + `just`, so it can still rebuild
          itself from the checkout).
        '';
      }
    )

    # zen3-nixos as this machine's remote Nix build server, with local
    # builds kept as a fallback (self-disabling on zen3 itself).
    ./build-client.nix

    # The forked DeepSeek Harness Web GUI as an always-on LAN service —
    # declared authorities are the operator's own surface (see
    # common/dsh-web-service.nix and docs/dsh-fork/). Off by default; enable
    # services.dshWebHarness on the host that should serve it.
    ./dsh-web-service.nix
  ];

  # Every host gets the fleet CLI set unless it says otherwise (see the option
  # doc in the nested module above); `mkDefault` so a host can turn it off with
  # a plain `sharedPackages.enable = false;`.
  sharedPackages.enable = lib.mkDefault true;

  system.updateContainers = {
    enable = true;
    webhookUrl = "https://notify.home.chrisdell.info";
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  boot.kernelParams = [
    "mitigations=off"
  ];

  networking.firewall.enable = false;

  services.openssh.enable = true;

  programs.nix-ld.enable = true;

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

  environment.systemPackages = lib.optionals cfg.enable (
    with pkgs;
    [
      dmidecode
      git
      nmap
      inetutils
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
      _7zz
      ethtool
      flashrom
      ch341eeprom
      smartmontools
      gptfdisk
      just

      # GPU Related Stuff
      intel-gpu-tools
      radeontop
      amdgpu_top
      mesa-demos
      clinfo
      vulkan-tools
      vdpauinfo
      libva-utils

      # Programming
      deno
      cargo
      cargo-binutils
      rustup
      gh # GitHub CLI
      nixfmt
      alejandra
      nil
      nixd
    ]
  );

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?
}
