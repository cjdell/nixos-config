{ config, lib, ... }:

# Shared folding@home space-heater wiring — the common half of every
# hosts/*/folding-heater.nix (and kabylakeitx-nixos/folding.nix). A host
# imports this and only sets what is host-specific: cpus/gpuUsage/enableGpu/
# startDelay, the fah-panel backend options, and any vendor-specific
# environment overrides.
#
# What it provides:
#   * common/folding-at-home-native.nix + common/fah-panel.nix imports
#   * the shared FAH account token (secrets/fah.yaml, fleet age key)
#   * the standard Web Control listen/allow list
#   * the "heater never sleeps" logind settings
#   * fah-panel enabled (host sets the backend options)
{
  imports = [
    ./fah-panel.nix
    ./folding-at-home-native.nix
  ];

  services.folding-at-home-native = {
    enable = true;
    userName = "cjdell";
    teamNumber = 236565;
    httpAddresses = [ "0.0.0.0:7396" ];
    allowAddresses = [
      "127.0.0.1" # loopback — fah-provision and local fahctl connect here
      "::1"
      "192.168.49.0/24" # LAN
      "10.47.0.0/16" # WireGuard
      "100.64.0.0/10" # tailnets
    ];
    # Links this machine to the FAH account (it then shows up in
    # app.foldingathome.org next to the rest of the fleet). secrets/fah.yaml
    # is encrypted to the shared fleet age key, i.e. the
    # /var/lib/sops-nix/key.txt provisioned on every sops-enabled host.
    accountTokenFile = config.sops.secrets.fah_account_token.path;
  };

  sops.secrets.fah_account_token = {
    sopsFile = ../secrets/fah.yaml;
    restartUnits = [ "fah-client.service" ];
  };

  services.fah-panel.enable = lib.mkDefault true;

  # A heater never sleeps; logind refuses suspend/hibernate requests
  # (PowerDevil's idle actions included).
  systemd.sleep.settings.Sleep = {
    AllowSuspend = lib.mkDefault "no";
    AllowHibernation = lib.mkDefault "no";
    AllowHybridSleep = lib.mkDefault "no";
    AllowSuspendThenHibernate = lib.mkDefault "no";
  };
}
