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

  # sops-nix mounts secret generations under /run/secrets.d and makes
  # /run/secrets a symlink to the current one. virtiofsd's sandbox bind-mounts
  # the shared directory with move_mount(..., MOVE_MOUNT_F_EMPTY_PATH), which
  # refuses a symlink target (EINVAL) -> virtiofsd-secrets crash-loops and the
  # microVM never starts. Give the VM share a stable real (bind-mounted) path.
  system.activationScripts.secrets-vm = lib.stringAfter [ "setupSecrets" ] ''
    target="$(${pkgs.coreutils}/bin/readlink -f /run/secrets)"
    if [ -n "$target" ] && [ -d "$target" ]; then
      ${pkgs.coreutils}/bin/mkdir -p /run/secrets-vm
      if ${pkgs.util-linux}/bin/mountpoint -q /run/secrets-vm; then
        ${pkgs.util-linux}/bin/umount /run/secrets-vm || true
      fi
      ${pkgs.util-linux}/bin/mount --bind "$target" /run/secrets-vm
    fi
  '';

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

        # Root login was password-only, so when the leighhack tunnel died there
        # was NO way in to run `tailscale status`: no key auth, no VSOCK
        # (`microvm -s` refuses), and the serial console is qemu's stdio with no
        # QMP-rebindable device id (QEMU 11 refuses `chardev-change` on an
        # already-realized anonymous isa-serial). Give the same admin keys the
        # host has, so `ssh root@192.168.49.15` always works — the LAN path is
        # independent of tailscale, so it still works when the tunnel is dead.
        users.users.root.openssh.authorizedKeys.keys =
          config.users.users.cjdell.openssh.authorizedKeys.keys
          # Dedicated keypair held by the host (sops) so the health check can
          # name the failing layer instead of just "it is down". Public half is
          # not secret; the private half is `grafton_hackspace_client_ssh_key`.
          ++ [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF896J8Mhl9/r3R/8x8LlAVYIt+6O9A6sNpyfeJqpCgm grafton-router-health@grafton-router"
          ];

        # nixpkgs' tailscaled-autoconnect is Type=notify, runs under
        # `set -o errexit`, calls `tailscale up` only while the backend state is
        # NeedsLogin/NeedsMachineAuth/Stopped, and signals READY only once it
        # reaches Running. It has no Restart=, so ONE failed or timed-out
        # registration attempt kills it permanently - which is exactly what
        # happened on 2026-10-09: the console shows "Starting
        # tailscaled-autoconnect.service..." and never shows it started, so the
        # VM never registered and never appeared on the hackspace headscale, for
        # 5 days. Retry instead of dying.
        systemd.services.tailscaled-autoconnect = {
          serviceConfig = {
            Restart = "on-failure";
            RestartSec = "30s";
            # generous: the failure path never sd_notifies, so a hang is only
            # visible as a start timeout
            TimeoutStartSec = "5min";
          };
        };

        # Diagnostic tools. During the 2026-10 leighhack outage the VM had no
        # tcpdump and no dig, so "is the tunnel actually carrying traffic?" and
        # "does DNS work from inside?" could not be answered where it mattered.
        environment.systemPackages = with pkgs; [
          bind # dig / nslookup
          curl
          iputils # ping
          jq
          tcpdump
        ];

        system.activationScripts.addHostKey = ''
          mkdir -p /var/secrets
          # The host's sops secret is bind-mounted into /run/secrets
          # (microvm.shares below), so the private key is never committed.
          cat ${config.sops.secrets.vm_host_key.path} > /var/secrets/ssh_host_ed25519_key
          chmod 0400 /var/secrets/ssh_host_ed25519_key
        '';

        users.users.root.initialHashedPassword = "$y$j9T$8aqblMqV7q3.bcfzur3jd/$ldh1xzyCl4Dpq9QtPR76KTYSdhN3BmXB5kKFXiBKsU.";

        microvm = {
          # Persist the tailscale node identity across VM restarts.
          #
          # This VM had NO disk at all (no -drive/-blockdev/-pflash in the qemu
          # cmdline; root is the initrd tmpfs), so /var/lib/tailscale lived in
          # RAM and every `nixos-rebuild switch` that touched this VM started
          # from an empty state. tailscaled-autoconnect then has to re-register
          # with the single-use pre-auth key, and if that key is expired or
          # already consumed `tailscale up` fails, the unit exits (errexit) and
          # is never retried — the box sits in NeedsLogin forever with nothing
          # complaining. See docs/leighhack-tailscale.md.
          #
          # With the state on a volume the node key survives, so re-registration
          # (and therefore the key's expiry) is no longer on the critical path.
          volumes = [
            {
              image = "/var/lib/microvms/grafton-hackspace-client/tailscale-state.img";
              label = "tsstate";
              mountPoint = "/var/lib/tailscale";
              size = 32;
              fsType = "ext4";
            }
          ];

          shares = [
            {
              source = "/nix/store";
              mountPoint = "/nix/.ro-store";
              tag = "ro-store";
              proto = "virtiofs";
            }
            {
              # /run/secrets-vm is the resolved secrets dir, bind-mounted by
              # the secrets-vm activation script above (see the comment there
              # for why we can't hand virtiofsd the /run/secrets symlink).
              source = "/run/secrets-vm";
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
