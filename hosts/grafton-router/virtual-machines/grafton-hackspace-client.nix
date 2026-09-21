{
  config,
  lib,
  pkgs,
  ...
}:

let
  constants = import ../constants.nix;
in
{
  virtualisation.libvirtd = {
    enable = true;
    allowedBridges = [ "lan" ];
  };

  # journalctl -u grafton-hackspace-client-routes -f
  systemd.services.grafton-hackspace-client-routes = {
    description = "Grafton Hackspace Client Routes";

    wantedBy = [ "multi-user.target" ];

    after = [ "microvm-set-booted@grafton-hackspace-client.service" ];
    requires = [ "microvm-set-booted@grafton-hackspace-client.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${lib.getExe pkgs.bash} -c '${pkgs.iproute2}/bin/ip route show 10.3.0.0/16 via ${constants.GRAFTON_HACKSPACE_CLIENT_IP} | grep -q . || (for i in $(seq 1 30); do ${pkgs.iputils}/bin/ping -c1 -W1 ${constants.GRAFTON_HACKSPACE_CLIENT_IP} >/dev/null 2>&1 && break; sleep 1; done; ${pkgs.iproute2}/bin/ip route add 10.3.0.0/16 via ${constants.GRAFTON_HACKSPACE_CLIENT_IP})'";
    };
  };

  microvm.vms = {
    grafton-hackspace-client = {
      inherit pkgs;

      config = {
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "yes";
          hostKeys = [
            {
              bits = 256;
              path = "/var/secrets/ssh_host_ed25519_key";
              type = "ed25519";
            }
          ];
        };

        system.activationScripts.addHostKey = ''
          mkdir -p /var/secrets
          # The host's sops secret is bind-mounted into /run/secrets
          # (microvm.shares below), so the private key is never committed.
          cat ${config.sops.secrets.vm_host_key.path} > /var/secrets/ssh_host_ed25519_key
          chmod 0400 /var/secrets/ssh_host_ed25519_key
        '';

        users.users.root.initialHashedPassword = "$y$j9T$8aqblMqV7q3.bcfzur3jd/$ldh1xzyCl4Dpq9QtPR76KTYSdhN3BmXB5kKFXiBKsU.";

        microvm = {
          shares = [
            {
              source = "/nix/store";
              mountPoint = "/nix/.ro-store";
              tag = "ro-store";
              proto = "virtiofs";
            }
            {
              source = "/run/secrets";
              mountPoint = "/run/secrets";
              tag = "secrets";
              proto = "virtiofs";
              readOnly = true;
            }
          ];

          interfaces = [
            {
              type = "tap";
              # Interface name on the host
              id = "vm-ts1-tap";
              # Ethernet address of the MicroVM's interface, not the host's
              mac = "02:00:00:00:00:15";
            }
          ];
        };

        networking = {
          useDHCP = false;
          useNetworkd = true;

          nftables.enable = true;
          firewall.enable = false;
        };

        boot.kernel.sysctl = {
          "net.ipv4.conf.all.forwarding" = true;
          "net.ipv6.conf.all.forwarding" = true;
        };

        systemd.network = {
          enable = true;

          links = {
            "10-lan" = {
              matchConfig.Type = "ether";
              linkConfig = {
                Name = "br-host";
              };
            };
          };

          networks = {
            "10-lan" = {
              matchConfig.Name = "br-host";
              networkConfig = {
                IPv6AcceptRA = true;
                DHCP = "yes";
              };
            };
          };
        };

        services.tailscale = {
          enable = true;
          authKeyFile = config.sops.secrets.leigh_hackspace_tailscale_pre_auth_key.path;
          useRoutingFeatures = "client";
          extraUpFlags = [
            "--login-server=https://tailscale.leighhack.org"
            "--advertise-routes=192.168.49.0/24"
            "--advertise-exit-node"
            "--accept-dns=true"
            "--accept-routes=true"
          ];
        };

        networking.nftables.tables = {
          firewall = {
            family = "inet";
            content = ''
              chain input {
                type filter hook input priority filter; policy accept;
              }

              chain forward {
                type filter hook forward priority 0; policy accept;
              }

              chain output {
                type filter hook output priority 0; policy accept;
              }
            '';
          };

          # No masquerade (NAT) on br-host -> tailscale0: traffic must keep its
          # original source address so replies from grafton LAN hosts come back
          # end-to-end. The hackspace side (services1 + OPNsense static route)
          # knows how to reach 192.168.49.0/24 back through this VM, so replies
          # routed to the grafton LAN are delivered directly without NAT state.
        };

        system.stateVersion = "26.05";
      };
    };
  };
}
