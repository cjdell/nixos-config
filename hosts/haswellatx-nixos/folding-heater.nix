# haswellatx-nixos as a folding@home space heater — CPU side only.
#
# The i5-4460 is 4 Haswell threads with AVX2 (core_a4 folds happily, ~84 W
# TDP at the socket), so every thread folds and nothing is reserved.
#
# The Radeon R9 290 (Hawaii PRO, GCN2 / gfx700) CANNOT fold: ROCm's compute
# stack dropped gfx700 in 2018 (ROCm 2.0, ROCm/ROCm#871), so no OpenCL ICD
# available on a modern kernel can see it — amdgpu's CIK support
# (boot.kernelParams in hardware-configuration.nix) is display-only. The
# native client therefore enumerates no GPU slots and folds CPU-only; the
# previous linuxserver.io container deployment (folding-at-home.nix "none")
# was likewise AMD-blind, so nothing is lost.
#
# Web Control: http://192.168.49.54:7396/ ; the sops account token also links
# the machine into the FAH account (see the accountTokenFile below).
# Progress: `journalctl -u fah-client -f` or `tail /var/lib/fah-client/log.txt`.
{ config, ... }:

{
  imports = [ ../../common/folding-at-home-native.nix ];

  services.folding-at-home-native = {
    enable = true;
    userName = "cjdell";
    teamNumber = 236565;
    cpus = 4; # the whole i5-4460, nothing reserved
    httpAddresses = [ "0.0.0.0:7396" ];
    allowAddresses = [
      "127.0.0.1" # loopback — fah-provision and local fahctl connect here
      "::1"
      "192.168.49.0/24" # LAN
      "10.47.0.0/16" # WireGuard
      "100.64.0.0/10" # tailnets
    ];
    # Links this machine to the FAH account (it then shows up in
    # app.foldingathome.org next to zen1). secrets/fah.yaml is encrypted to
    # the shared fleet age key (the *cjdell recipient of .sops.yaml), i.e.
    # the /var/lib/sops-nix/key.txt provisioned on every sops-enabled host.
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
