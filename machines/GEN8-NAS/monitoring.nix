{ config, pkgs, ... }:

{
  services.prometheus.exporters = {
    node = {
      enable = true;
      port = 9100;
      enabledCollectors = [ "systemd" ];
      # Only allow monitoring server to scrape
      # openFirewall = true; # or manually configure firewall
    };
    systemd = {
      enable = true;
      port = 9558;
    };

    # ZFS exporter
    zfs = {
      enable = true;
      port = 9134;
    };

    # SMART exporter
    smartctl = {
      enable = true;
      port = 9633;
      # Specify which devices to monitor (optional, auto-detects if not set)
      # devices = [ "/dev/sda" "/dev/sdb" "/dev/nvme0n1" ];
    };
  };
}
