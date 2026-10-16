{
  config,
  lib,
  pkgs,
  ...
}:

let
  constants = import ../constants.nix;

  # How we join the leighhack tailnet — single source of truth. nixpkgs'
  # tailscaled-autoconnect (via services.tailscale.extraUpFlags) and the
  # keep-it-joined reconciler below must never disagree, or a re-registration
  # comes up without the subnet route this VM exists to advertise and the link
  # is silently one-way (see docs/leighhack-tailscale.md).
  leighUpFlags = [
    "--login-server=https://tailscale.leighhack.org"
    "--advertise-routes=192.168.49.0/24"
    "--advertise-exit-node"
    "--accept-dns=true"
    "--accept-routes=true"
  ];

  # Re-join the leighhack tailnet whenever the session dies, however it died.
  #
  # nixpkgs' tailscaled-autoconnect is a boot-time ONE-SHOT: it polls the
  # backend state, and the first time it sees `Running` it sd_notifies and
  # `exit 0`s. It never looks again. So any logout after boot — including one
  # we did not ask for — sits there dead forever, because `Restart=on-failure`
  # cannot fire on a clean exit.
  #
  # That is what happened 2026-10-16 08:21 UTC. The hackspace's headscale
  # deleted our node from under a healthy tunnel:
  #
  #   active login: <missing-profile>
  #   Switching ipn state Running -> NeedsLogin (WantRunning=true, nm=true)
  #   control: lite map update error: initial fetch failed 404: node not found
  #
  # `LocalAPI: Logout` appears zero times in the guest journal, so nobody here
  # logged out: control told us we no longer exist, and tailscaled's response
  # to that is indistinguishable from a logout. Nothing retried, and the tunnel
  # stayed down for 3 hours until a human restarted tailscaled-autoconnect.
  #
  # A node we do not control can be deleted at any time, so the answer is not a
  # better alert but a loop that keeps the session joined: worst-case outage is
  # now the timer interval instead of "until someone notices".
  leighEnsure = pkgs.writeShellScript "hackspace-tailscale-ensure" ''
    set -u

    TS=${pkgs.tailscale}/bin/tailscale
    KEY=${config.sops.secrets.leigh_hackspace_tailscale_pre_auth_key.path}

    state=$($TS status --peers=false --json 2>/dev/null \
      | ${pkgs.gnugrep}/bin/grep -o '"BackendState": *"[A-Za-z]*"' \
      | ${pkgs.coreutils}/bin/cut -d'"' -f4)

    case "$state" in
      Running)
        # healthy — the overwhelmingly common case, and the reason this stays quiet
        exit 0 ;;
      NeedsLogin | NeedsMachineAuth | Stopped)
        # NeedsLogin does NOT imply a bad key. See the 404: node not found
        # post-mortem above; the key is reusable and this is the path that
        # recovers from a server-side deletion, an expired node key, or an admin
        # pruning this node out of their headscale.
        echo "leighhack session is '$state' — re-registering with the pre-auth key"
        $TS up --auth-key "$(${pkgs.coreutils}/bin/cat "$KEY")" ${lib.escapeShellArgs leighUpFlags}
        echo "re-registered: tailscale is now $($TS status --peers=false --json 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -o '"BackendState": *"[A-Za-z]*"' \
          | ${pkgs.coreutils}/bin/cut -d'"' -f4)"
        # A fresh registration starts WITHOUT the return route for
        # 192.168.49.0/24 on their headscale, so expect the link to be one-way
        # for a few minutes. That is their ACL, not a failure here — see docs.
        ;;
      *)
        # NoState / Starting / empty: tailscaled is mid-handshake (normally at
        # boot, where tailscaled-autoconnect owns it). Do not race it.
        exit 0 ;;
    esac
  '';
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
          extraUpFlags = leighUpFlags;
        };

        # The keep-it-joined loop. Runs in the GUEST (this whole attrset is the
        # microVM's config), independent of the host's health timer, because the
        # host cannot re-register a session it does not hold.
        systemd.services.hackspace-tailscale-ensure = {
          description = "Keep the leighhack tailnet joined (re-register after a server-side logout)";
          after = [
            "tailscaled.service"
            "network-online.target"
          ];
          wants = [ "tailscaled.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = leighEnsure;
            # `tailscale up` blocks until the login completes, so a hang (not
            # just a rejection) has to be cut short for the next tick to run.
            TimeoutStartSec = "2min";
          };
        };

        systemd.timers.hackspace-tailscale-ensure = {
          description = "Re-join the leighhack tailnet within a minute if the session dropped";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            Unit = "hackspace-tailscale-ensure.service";
            OnBootSec = "1min";
            OnUnitActiveSec = "1min";
            RandomizedDelaySec = "10s";
          };
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
