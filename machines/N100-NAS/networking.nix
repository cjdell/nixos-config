{
  config,
  pkgs,
  lib,
  ...
}:

{
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkForce false;

  # networking.wireless.enable = true;  # Enable wpa_supplicant

  # # WiFi network configuration
  # networking.wireless.networks = {
  #   "The Lab" = {
  #     psk = "Graft0nSt.";
  #   };
  # };

  # # Explicitly set interface for wpa_supplicant
  # networking.wireless.interfaces = [ "wlp4s0" ];

  systemd.network = {
    enable = true;

    netdevs = {
      "20-br0" = {
        netdevConfig = {
          Name = "br0";
          Kind = "bridge";
          MACAddress = "00:e0:4d:02:cd:56";
        };
      };
    };

    networks = {
      # # WiFi interface configuration
      # "10-wlp4s0" = {
      #   matchConfig.Name = "wlp4s0";
      #   networkConfig.DHCP = "yes";
      #   linkConfig.RequiredForOnline = "routable";
      # };

      "21-br0-en" = {
        matchConfig.Name = "en*";
        networkConfig.Bridge = "br0";
      };

      "22-br0" = {
        matchConfig.Name = "br0";
        linkConfig.RequiredForOnline = "routable";
        networkConfig.DHCP = "yes";
      };
    };
  };
}
