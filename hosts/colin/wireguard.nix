{ config, pkgs, ... }:

{
  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    wg0 = {
      # Determines the IP address and subnet of the client's end of the tunnel interface.
      ips = [ "10.47.98.10/16" ];
      listenPort = 51820; # to match firewall allowedUDPPorts (without this wg uses random port numbers)

      # This allows the wireguard server to route your traffic to the internet and hence be like a VPN
      # For this to work you have to set the dnsserver IP of your router (or dnsserver of choice) in your clients
      postSetup = ''
        ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 10.47.0.0/16 -o eno1 -j MASQUERADE
      '';

      # This undoes the above command
      postShutdown = ''
        ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 10.47.0.0/16 -o eno1 -j MASQUERADE
      '';

      # Path to the private key file, from sops (hosts/colin/secrets/secrets.yaml).
      privateKeyFile = config.sops.secrets.wireguard_key.path;

      peers = [
        # For a client configuration, one peer entry for the server will suffice.

        {
          # Public key of the server (not a file path).
          publicKey = "gNxnNaKmHNOtA7n38aGdCl1KfD7X+c1CXZg/D89CYiY=";

          # Forward all the traffic via VPN.
          # allowedIPs = [ "0.0.0.0/0" ];
          # Or forward only particular subnets
          allowedIPs = [ "10.47.0.0/16" ];

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

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_pre_auth_key.path;
    extraUpFlags = [
      "--login-server=https://tailscale.home.chrisdell.info"
      "--advertise-routes=192.168.178.0/24"
      "--accept-routes=false"
      "--accept-dns=false"
    ];
  };
}
