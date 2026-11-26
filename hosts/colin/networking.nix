{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  constants = import ./constants.nix;
in
{
  # networking.hostName comes from mkHost ({ networking.hostName = "colin"; }
  # in flake.nix) — it must match the hosts/<name> directory.
  networking.enableIPv6 = false; # TalkTalk *still* don't support IPv6

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  services.create_ap = {
    enable = true;
    settings = {
      INTERNET_IFACE = "eno1";
      WIFI_IFACE = "wlp1s0";
      SSID = constants.SSID;
      PASSPHRASE = config.sops.placeholder.ap_passphrase;
    };
  };

  # The create_ap module normally bakes settings into a store file, so the
  # passphrase would be world-readable in /nix/store. Render the same KeyValue
  # config through sops instead and point the unit at the rendered file.
  sops.templates."create_ap.conf".content =
    lib.generators.toKeyValue { }
      config.services.create_ap.settings;

  systemd.services.create_ap = {
    restartTriggers = lib.mkForce [ config.sops.templates."create_ap.conf".path ];
    serviceConfig.ExecStart = lib.mkForce "${pkgs.linux-wifi-hotspot}/bin/create_ap --config ${
      config.sops.templates."create_ap.conf".path
    }";
  };

  # Enable NAT
  networking.nat.enable = true;
  networking.nat.externalInterface = "eno1";
  networking.nat.internalInterfaces = [ "wg0" ];

  systemd.timers.ping-reboot = {
    description = "Ping Reboot Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "10min";
      Unit = "ping-reboot.service";
    };
  };
  systemd.services.ping-reboot = {
    description = "Ping Reboot Service";
    script = ''
      set -Eeuxo pipefail

      ${pkgs.coreutils-full}/bin/echo "Starting ping reboot..."

      # IP address to ping
      IP_ADDRESS="8.8.8.8"

      # Number of ping attempts
      PING_COUNT=4

      # Ping the IP address and capture the output
      PING_OUTPUT=$(${pkgs.iputils}/bin/ping -c $PING_COUNT $IP_ADDRESS || ${pkgs.coreutils-full}/bin/true)

      echo ${pkgs.coreutils-full}/bin/echo PING_OUTPUT = $PING_OUTPUT

      # Extract packet loss percentage from the output
      PACKET_LOSS=$(${pkgs.coreutils-full}/bin/echo "$PING_OUTPUT" | ${pkgs.gnugrep}/bin/grep -oP '\d+(?=% packet loss)')

      echo ${pkgs.coreutils-full}/bin/echo PACKET_LOSS = $PACKET_LOSS

      # Check if the packet loss is 100%
      if [ "$PACKET_LOSS" -eq 100 ]; then
        ${pkgs.coreutils-full}/bin/echo "REBOOTING!!!"

        # If ping fails, reboot the system
        ${pkgs.systemd}/bin/reboot
      else
        ${pkgs.coreutils-full}/bin/echo "Success pinging $IP_ADDRESS"
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };
}
