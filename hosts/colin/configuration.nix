# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ pkgs, ... }:

let
  constants = import ./constants.nix;
in
{
  nix.extraOptions = "experimental-features = nix-command flakes";

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Set your time zone.
  time.timeZone = "Europe/London";

  users.users.admin = {
    uid = constants.ADMIN_UID;
    group = "users";
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.cjdell = {
    uid = 1000;
    group = "users";
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCbDJ7tQwODw2kx2f1bstOUElKnaR3hP2RbwCsf6zebZ5n/1CFUoM2Ye78D/IG/6kgDc22wD9EkzyvIwF/96fp3IgxK5ja/Q0pEhbd8xAPGIpFC7BUyePqozRusSvJXl7RamBb8lgsjySQxJxYX9MQzbQkfasWOwWE+WWqiC9nwk6WiER7EraOdEVNNF9cuNS/LVFrQZG5xdzI5gSgaxth2kQSgE3z7jIIvmlYkChEjTMXSQt9MrluhWB1nzGDHVrcqW8uu/jAqeMhRCXP39wtmL21v3WFn1jwDQlOgbR1CxnBzy+jE62TqvOJg8x6/J2WC/VXcdndHq1vKYP0s5mQn cjdell@gmail.com"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    nano
    micro
    wget
    nixfmt-rfc-style
    alejandra
    nixd
    nil
    iptables
    tmux
    git
    inetutils
    dmidecode
    pciutils
    pcimem
    nfs-utils
    openssl
    usbutils
    unzip
    fwupd
    lm_sensors
    libva-utils
    intel-gpu-tools
    nmap
    iotop
    speedtest-rs
    ethtool
    iw
    psmisc
    sysstat
    hdparm
    dool # dool -cdmln 1
    gptfdisk
    parted
    ffmpeg
  ];

  programs.nix-ld.enable = true;

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "24.11"; # Did you read the comment?
}
