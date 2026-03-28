{
  config,
  pkgs,
  lib,
  ...
}:

{
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkForce false;

  systemd.network = {
    enable = true;

    netdevs = {
      "20-br0" = {
        netdevConfig = {
          Name = "br0";
          Kind = "bridge";
          MACAddress = "e4:11:5b:12:c2:ab";
        };
      };
    };

    networks = {
      "21-br0-en" = {
        matchConfig.Name = [
          #"eno1"
          #"eno2"
          "enp3s0"
        ];
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
