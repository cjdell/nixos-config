{ config, ... }:

# zen1-nixos is the folding@home space heater: Ryzen 7 1800X (8c/16t) and an
# RX 5700 XT (gfx1010), folding at full tilt — all 16 CPU threads plus the
# GPU via the ROCm 6.4.3 OpenCL runtime (see common/fah-packages.nix).
#
# Web Control: http://192.168.49.51:7396/ (redirects to app.foldingathome.org)
# or via the Folding@home account this machine is linked to with the sops
# account token. Progress: `journalctl -u fah-client -f` or
# `tail /var/lib/fah-client/log.txt`.
{
  imports = [ ../../common/folding-at-home-native.nix ];

  services.folding-at-home-native = {
    enable = true;
    userName = "cjdell";
    teamNumber = 236565;
    cpus = 16; # the whole 1800X, nothing reserved
    httpAddresses = [ "0.0.0.0:7396" ];
    allowAddresses = [
      "127.0.0.1" # loopback — fah-provision and local fahctl connect here
      "::1"
      "192.168.49.0/24" # LAN
      "10.47.0.0/16" # WireGuard
      "100.64.0.0/10" # tailnets
    ];
    accountTokenFile = config.sops.secrets.fah_account_token.path;
  };

  sops.secrets.fah_account_token = {
    sopsFile = ../../secrets/fah.yaml;
    restartUnits = [ "fah-client.service" ];
  };

  # A heater never sleeps; logind refuses suspend/hibernate requests
  # (PowerDevil's idle actions included).
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
}
