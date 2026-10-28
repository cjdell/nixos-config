{ config, ... }:

# zen1-nixos is the folding@home space heater: Ryzen 7 1800X (8c/16t) and an
# RX 5700 XT (gfx1010), folding at full tilt — all 16 CPU threads plus the
# GPU via the ROCm 6.4.3 OpenCL runtime (see common/fah-packages.nix).
#
# Web Control: http://192.168.49.51:7396/ (redirects to app.foldingathome.org)
# or via the Folding@home account this machine is linked to with the sops
# account token. Progress: `journalctl -u fah-client -f` or
# `tail /var/lib/fah-client/log.txt`.
#
# Heater panel: http://192.168.49.51/ (fah-panel, same app as the
# asus-i7-6700's, here with the amdgpu sysfs backend — gpu_busy_percent/hwmon/pp_dpm on the
# RX 5700 XT and k10temp/RAPL on the 1800X, plus the live power-cap slider
# writing hwmon power1_cap; the 75–150 W range this VBIOS exposes is read at
# startup, verified writable on the default ppfeaturemask).
{
  imports = [
    ../../common/fah-panel.nix
    ../../common/folding-at-home-native.nix
  ];

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

  # Same panel binary as the asus-i7-6700 heater, AMD backend (see crates/fah-panel).
  # No --budget here: this is a proper AM4 desktop PSU, not the old Z240's
  # brownout-prone SFF one, so the DC-load card just reports without a marker.
  services.fah-panel = {
    enable = true;
    gpu = "amd";
    # Navi 10 XT (RX 5700 XT). Id, not BDF — ids survive PCIe re-enumeration.
    amdPci = "1002:731f";
    gpuName = "Radeon RX 5700 XT";
    # The 1800X sits pinned at Tjmax (Tctl ~95 °C) while folding all 16
    # threads, so hold it at 80 °C: the panel ramps scaling_max_freq down
    # until Tctl sits there (~3.2-3.4 GHz in practice) and back up when the
    # chip cools. Startup target = this option (survives restarts/reboots);
    # the panel slider overrides it live for the running service.
    cpuTempTarget = 80;
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
