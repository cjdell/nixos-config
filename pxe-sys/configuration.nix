{ config, pkgs, ... }:

{
  networking.hostName = "pxeclient";

  # nixpkgs.config.allowUnfree = true;

  boot.kernelParams = [
    "mitigations=off"
    "shell-on-fail=1"
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  hardware.firmware = [ pkgs.linux-firmware ];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    hostKeys = [
      {
        bits = 256;
        path = "/var/secrets/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  system.activationScripts.addHostKey = ''
    mkdir -p /var/secrets
    cat ${./ssh_host_ed25519_key} > /var/secrets/ssh_host_ed25519_key
    chmod 0400 /var/secrets/ssh_host_ed25519_key
  '';

  programs.nix-ld.enable = true;

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

  # # Allow the user to log in as root without a password.
  users.users.root.initialHashedPassword = "";

  # Don't require sudo/root to `reboot` or `poweroff`.
  security.polkit.enable = true;

  # Allow passwordless sudo from nixos user
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  environment.systemPackages = with pkgs; [
    openldap # for ldapsearch
    nano
  ];

  security.pki.certificates = [
    # leighhack.org (Root CA)
    ''
      -----BEGIN CERTIFICATE-----
      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
      fBbCwgkaci4r5pMqKjOy7DHKcoQRerA=
      -----END CERTIFICATE-----
    ''
  ];

  system.stateVersion = config.system.nixos.release;
}
