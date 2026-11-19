{ config, ... }:

let
  net = import ../networking/constants.nix;
in
{
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_pre_auth_key.path;
    useRoutingFeatures = "server";
    extraUpFlags = [
      "--login-server=https://tailscale.home.chrisdell.info"
      # The LAN (both families) + the re-advertised hackspace LAN.
      # The 10.3.0.0/16 entry documents/repairs drift: it had been
      # advertised all along, but only by a manual `tailscale up` — a later
      # config-driven `up` silently dropped it from the advertisement (and
      # headscale keeps it Approved+Serving until re-offered), so it lives
      # here now. The v6 /64 joined 2026-11-19 so tailnet members can reach
      # LAN hosts over IPv6 via us (2a02:8010:6680:49::50 etc.) instead of
      # depending on the ISP's delegation staying routable from the internet.
      # It pins the delegation, so if Zen ever re-delegates (verify per
      # networking/constants.nix!) this line follows LAN_IPV6_SUBNET and the
      # approval must move too: `headscale nodes approve-routes` REPLACES the
      # approved set — re-approve everything from `headscale nodes list-routes`
      # plus the new /64 in one command. Rejected by policy?
      # headscale.policy.path is /dev/null = allow-all, no ACL to edit.
      # NB: nixpkgs' tailscaled-autoconnect is a boot-time one-shot that exits
      # once the backend is Running — after editing this list, apply it with
      # `sudo tailscale up --login-server=… <the flags>` (or restart BOTH
      # tailscaled and tailscaled-autoconnect), or the running node keeps
      # advertising the old set.
      # The hackspace v6 /48s joined 2026-11-19 so tailnet members can reach
      # gw/services there directly, symmetric through the VM: this router
      # masquerades member sources into hackspace space (hackspace-v6-nat,
      # networking/firewall.nix — needed because fd7a/100.64 collide with
      # leighhack's own ranges), the VM's nat6 then presents the one node
      # their ACLs admit. Unadvertised, a member's ping6 2001:8b0:… just
      # rides the public internet and meets their WAN ingress policy instead.
      "--advertise-routes=192.168.49.0/24,${net.HACKSPACE_SUBNET},${net.LAN_IPV6_SUBNET},${net.HACKSPACE_IPV6_SUBNET},${net.HACKSPACE_ULA_SUBNET}"
      "--advertise-exit-node"
      "--accept-dns=false"
      # Accept the tailnet's approved subnet routes so the LAN can reach them
      # (the firewall + masquerade per-subnet, see networking/firewall.nix).
      # Currently approved: gatling-services 10.0.1.0/24, colin 192.168.178.0/24,
      # dbthr33-server 192.168.35.0/24.
      "--accept-routes=true"
    ];
  };

  # networking.nat = {
  #   enable = true;
  #   # Use "ve-*" when using nftables instead of iptables
  #   internalInterfaces = [ "ve-*" ];
  #   externalInterface = "pppoe-zen";
  #   # Lazy IPv6 connectivity for the container
  #   enableIPv6 = true;
  # };

  # # sudo nixos-container root-login tailscale-client-hackspace
  # containers.tailscale-client-hackspace = {
  #   autoStart = true;
  #   bindMounts."${config.sops.secrets.leigh_hackspace_tailscale_pre_auth_key.path}".isReadOnly = true;
  #   enableTun = true;
  #   timeoutStartSec = "15min";

  #   privateNetwork = true;
  #   hostAddress = "192.168.100.1";
  #   localAddress = "192.168.100.11";
  #   hostAddress6 = "fc00::1";
  #   localAddress6 = "fc00::11";

  #   config =
  #     {
  #       containerConfig,
  #       pkgs,
  #       lib,
  #       ...
  #     }:
  #     {

  #       services.httpd = {
  #         enable = true;
  #         adminAddr = "admin@example.org";
  #       };

  #       networking = {
  #         # firewall.allowedTCPPorts = [ 80 ];
  #         firewall.enable = false;

  #         # Use systemd-resolved inside the container
  #         # Workaround for bug https://github.com/NixOS/nixpkgs/issues/162686
  #         useHostResolvConf = lib.mkForce false;

  #         resolvconf = {
  #           extraConfig = ''
  #             name_servers=192.168.49.1
  #           '';
  #         };

  #         nat = {
  #           enable = true;
  #           # Use "ve-*" when using nftables instead of iptables
  #           internalInterfaces = [ "eth0@+" ];
  #           externalInterface = "tailscale0";
  #         };
  #       };

  #       services.resolved.enable = true;

  #       services.tailscale = {
  #         enable = true;
  #         authKeyFile = config.sops.secrets.leigh_hackspace_tailscale_pre_auth_key.path;
  #         useRoutingFeatures = "client";
  #         # interfaceName = "userspace-networking";
  #         extraUpFlags = [
  #           "--login-server=https://tailscale.leighhack.org"
  #           "--advertise-routes=192.168.49.0/24"
  #           "--advertise-exit-node"
  #           "--accept-dns=true"
  #           "--accept-routes=true"
  #         ];
  #       };

  #       system.stateVersion = "26.05";
  #     };
  # };
}
