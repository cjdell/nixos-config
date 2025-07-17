{ config, lib, pkgs, modulesPath, ... }:

{
  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    wg0 = {
      # Determines the IP address and subnet of the client's end of the tunnel interface.
      ips = [ "10.47.49.21/16" ];
      listenPort = 51820; # to match firewall allowedUDPPorts (without this wg uses random port numbers)

      # This allows the wireguard server to route your traffic to the internet and hence be like a VPN
      # For this to work you have to set the dnsserver IP of your router (or dnsserver of choice) in your clients
      postSetup = ''
        ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 10.47.0.0/16 -o enp3s0 -j MASQUERADE

        ${pkgs.iproute2}/bin/ip route add default via 10.47.0.1 dev wg0 table 200

        MAC_IP_ADDRESS=192.168.49.149
        ${pkgs.iproute2}/bin/ip rule add from $MAC_IP_ADDRESS lookup 200
        ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s $MAC_IP_ADDRESS/32 -o wg0 -j MASQUERADE
        ${pkgs.iptables}/bin/iptables -A FORWARD -s $MAC_IP_ADDRESS/32 -o wg0 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -A FORWARD -d $MAC_IP_ADDRESS/32 -i wg0 -j ACCEPT
      '';

      # This undoes the above command
      postShutdown = ''
        # ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 10.47.0.0/16 -o enp3s0 -j MASQUERADE

        ${pkgs.iproute2}/bin/ip route del default via 10.47.0.1 dev wg0 table 200

        MAC_IP_ADDRESS=192.168.49.149
        ${pkgs.iproute2}/bin/ip rule del from $MAC_IP_ADDRESS lookup 200
        ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s $MAC_IP_ADDRESS/32 -o wg0 -j MASQUERADE
        ${pkgs.iptables}/bin/iptables -D FORWARD -s $MAC_IP_ADDRESS/32 -o wg0 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -D FORWARD -d $MAC_IP_ADDRESS/32 -i wg0 -j ACCEPT
      '';

      # Path to the private key file.
      #
      # Note: The private key can also be included inline via the privateKey option,
      # but this makes the private key world-readable; thus, using privateKeyFile is
      # recommended.
      privateKeyFile = "/home/cjdell/nixos-config/secrets/wireguard.key";

      peers = [
        # For a client configuration, one peer entry for the server will suffice.

        {
          # Public key of the server (not a file path).
          publicKey = "gNxnNaKmHNOtA7n38aGdCl1KfD7X+c1CXZg/D89CYiY=";

          # Forward all the traffic via VPN.
          # allowedIPs = [ "0.0.0.0/0" ];
          # Or forward only particular subnets
          allowedIPs = [ "10.47.0.0/16" "192.168.35.0/24" ];

          # Set this to the server IP and port.
          endpoint = "ovh-nix.chrisdell.info:51820"; # ToDo: route to endpoint not automatically configured https://wiki.archlinux.org/index.php/WireGuard#Loop_routing https://discourse.nixos.org/t/solved-minimal-firewall-setup-for-wireguard-client/7577

          # Send keepalives every 25 seconds. Important to keep NAT tables alive.
          persistentKeepalive = 25;
        }
      ];
    };
  };

  services.cron = {
    enable = true;
    systemCronJobs = [
      # WireGuard keeps going offline so restart every 5 minutes (doesn't interrupt connections)
      "*/5 * * * * root ${pkgs.systemd}/bin/systemctl restart wireguard-wg0"
    ];
  };

  # Enable NAT
  networking.nat.enable = true;
  networking.nat.externalInterface = "br0";
  networking.nat.internalInterfaces = [ "wg0" ];
}
