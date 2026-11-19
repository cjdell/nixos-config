{
  config,
  pkgs,
  ...
}:

let
  constants = import ../constants.nix;
  stateDir = "/var/lib/hackspace-tunnel-check";

  # Checks the leighhack tailnet bridge end-to-end and pushes to the phone via
  # the local notifications gateway (`notifications.gateway`, see http.nix)
  # when it breaks.
  #
  # Why this exists: the grafton tailnet (services/tailscale.nix) and the
  # leighhack tailnet (virtual-machines/grafton-hackspace-client.nix) are two
  # unrelated connections, and when the second one died nothing said so. The VM
  # stayed up, kept answering ping, kept owning the 10.3.0.0/16 route, and every
  # consumer of `*.int.leighhack.org` (adguard.nix forwards that zone to
  # 10.3.1.1:53) just silently failed to resolve. It was found by a human
  # noticing that a page would not load. Post-mortem: docs/leighhack-tailscale.md
  #
  # Alert-only on purpose: it never restarts the VM. A restart is the usual fix,
  # but while the VM had no persistent tailscale state a restart also spent a
  # pre-auth key, so auto-healing could have turned "down and diagnosable" into
  # "down and unrecoverable without a new key from leigh".
  check = pkgs.writeShellScript "hackspace-tunnel-check" ''
        set -u

        VM_IP=${constants.GRAFTON_HACKSPACE_CLIENT_IP}
        HACKSPACE_IP=10.3.1.1
        NOTIFY_URL=http://127.0.0.1:8888
        STATE_DIR=${stateDir}
        SSHKEY=${config.sops.secrets.grafton_hackspace_client_ssh_key.path}
        RE_ALERT_SECS=1800   # keep alerting every 30 min while it stays down
        # ~10 min of continuous failure before paging. Deliberately generous:
        # after the VM re-registers with the hackspace's headscale, the link can
        # be one-way (VM reaches 10.3.1.1, our traffic black-holes) for minutes
        # until their side has the return route for the new node - observed
        # ~20 min on 2026-10-14. Alerting inside that window would page on every
        # planned rebuild and teach us to ignore it.
        FAIL_THRESHOLD=5

        # Run one command inside the bridge VM. Without this the checker could
        # only ever report "it is down"; with it the alert names the layer, and
        # the two failure modes that look identical from here (logged out vs.
        # logged in but one-way) get different remediation.
        vmcmd() {
          ${pkgs.openssh}/bin/ssh -i "$SSHKEY" -o BatchMode=yes -o LogLevel=ERROR \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 "root@$VM_IP" "$1" 2>/dev/null
        }

        mkdir -p "$STATE_DIR"
        now=$(${pkgs.coreutils}/bin/date +%s)
        prev=$(${pkgs.coreutils}/bin/cat "$STATE_DIR/state" 2>/dev/null || echo unknown)
        fails=$(${pkgs.coreutils}/bin/cat "$STATE_DIR/fails" 2>/dev/null || echo 0)
        last_alert=$(${pkgs.coreutils}/bin/cat "$STATE_DIR/last-alert" 2>/dev/null || echo 0)

        # --- layer 1: is the route that sends 10.3/16 into the VM installed? -----
        if ${pkgs.iproute2}/bin/ip route show 10.3.0.0/16 | ${pkgs.gnugrep}/bin/grep -q .
        then route=ok; else route=missing; fi

        # --- layer 2: is the microVM itself up? ----------------------------------
        if ${pkgs.iputils}/bin/ping -c1 -W2 "$VM_IP" >/dev/null 2>&1
        then vm=up; else vm=down; fi

        # --- layer 3: does traffic actually reach the leighhack side? ------------
        # ICMP first, then a TCP connect to services1's DNS port: a tailnet that
        # drops echoed requests but forwards TCP must not make us cry wolf.
        if ${pkgs.iputils}/bin/ping -c2 -W2 "$HACKSPACE_IP" >/dev/null 2>&1
        then tunnel=up
        elif ${pkgs.coreutils}/bin/timeout 5 ${pkgs.bash}/bin/bash -c \
            "exec 3<>/dev/tcp/$HACKSPACE_IP/53" 2>/dev/null
        then tunnel=up
        else tunnel=down; fi

        # --- layer 4: does their IPv6 door actually ADMIT us? ---------------------
        # Layers 1-3 all stayed green through 794 consecutive HTTP 403s on
        # 2026-11-19: the hackspace's hand-written allow-row for our IPv6
        # stopped matching what we send (the handover note blamed a Zen
        # re-delegation — it had NOT happened, docs/leighhack-tailscale.md),
        # and every IPv6 request to *.int.leighhack.org was answered at the
        # application layer. Reachability checks cannot see that class of
        # fault — this one can, and it reads the status code instead of just
        # the socket: any HTTP answer at all means the v6 path (route via the
        # VM + their ACL) works end to end; 403 means our SOURCE is what they
        # reject, which is a different sentence to page with than "the tunnel
        # is down".
        V6_PROBE_URL=https://network-info.int.leighhack.org/healthz
        v6code=$(${pkgs.curl}/bin/curl -6 -sS -o /dev/null -m 15 -w '%{http_code}' "$V6_PROBE_URL" 2>/dev/null || true)
        # Beware the two-quote escape: this whole script is a Nix indented
        # string, so an unescaped dollar-brace is interpolated by Nix itself
        # first. The original source read two-quotes-escaped dollar-brace
        # "v6code:-000" — Nix evaluated that as a STRING LITERAL and collapsed
        # it to the bare text `v6code:-000` — bash then matched a CONSTANT,
        # never the HTTP code, so every probe fell to `*)` and the healthcheck
        # reported DOWN on perfect health: 39 consecutive false alarms, caught
        # by eyeballing a literal "curl code '200'" inside the DOWN message
        # (2026-11-19). After editing this file, check the GENERATED script,
        # not the Nix:
        #   grep -n case $(systemctl show hackspace-tunnel-check.service -p ExecStart | grep -oE '/nix/store/[^ ;"]+')
        case "''${v6code:-000}" in
          403)              v6=blocked ;;
          000)              v6=unreachable ;;
          [0-9][0-9][0-9])  v6=ok ;;
          *)                v6=unreachable ;;
        esac

        if [ "$route" = ok ] && [ "$vm" = up ] && [ "$tunnel" = up ] && [ "$v6" = ok ]; then
          healthy=1
          ${pkgs.coreutils}/bin/echo 0 > "$STATE_DIR/fails"
        else
          healthy=0
          fails=$((fails + 1))
          ${pkgs.coreutils}/bin/echo "$fails" > "$STATE_DIR/fails"
        fi
        ${pkgs.coreutils}/bin/echo "$healthy" > "$STATE_DIR/state"

        notify() {
          ${pkgs.curl}/bin/curl -fsS -m 15 -H 'Content-Type: application/json' \
            -d "{\"title\": \"$1\", \"message\": $(printf '%s' "$2" | ${pkgs.jq}/bin/jq -Rs .)}" \
            "$NOTIFY_URL" >/dev/null 2>&1 \
            || ${pkgs.coreutils}/bin/echo "WARN: notify gateway unreachable"
        }

        # Name the layer that failed, so the reader knows where to start.
        if [ "$route" = missing ]; then
          where="route 10.3.0.0/16 is not installed (networkd route on 100-lan, see networking/interface.nix; restart systemd-networkd)"
        elif [ "$vm" = down ]; then
          where="microVM grafton-hackspace-client ($VM_IP) does not answer ping"
        elif [ "$tunnel" = up ] && [ "$v6" = blocked ]; then
          # The failure 2026-11-19 actually was: everything we own is fine and
          # their door simply will not admit our v6 source any more.
          where="tunnel healthy, but the hackspace's IPv6 door answers us with HTTP 403 - OUR SOURCE is what they reject, the tunnel is NOT down. If 'ip -6 route show 2001:8b0:1d14::/48' is empty, the request is leaving via Zen as a WAN client again (networkd route on 100-lan, networking/interface.nix). If the route IS there, we arrive via the VM with the source they see in their access log (the VM's fd7a tailnet ULA, NATted by nat6 in virtual-machines/grafton-hackspace-client.nix) - a 403 then means their ACL changed, and it is leigh's to fix, not ours. A third variant, stale-but-not-403: Zen re-delegated and the house v6 went dead silently (compare 'ip -6 addr show lan' with LAN_IPV6_PREFIX in networking/constants.nix; docs/leighhack-tailscale.md)."
        elif [ "$tunnel" = up ] && [ "$v6" = unreachable ]; then
          where="v4 tunnel healthy, but IPv6 to $V6_PROBE_URL fails (curl code '$v6code') - the v6 routes via $VM_IP are missing (networking/interface.nix), the VM lost the hackspace's advertised /48s (ip -6 route show table all | grep 2001:8b0 in the VM), or the house IPv6 itself died: after a Zen re-delegation 'ip -6 addr show lan' must match LAN_IPV6_PREFIX in networking/constants.nix and the PD lease must be renewed (networkctl renew pppoe-zen; check 'journalctl -u systemd-networkd | grep delegated prefix')."
        else
          # The VM is up and the tunnel is not passing our traffic. Ask the VM
          # which of the two very different causes it is; from the host they look
          # identical.
          backend=$(vmcmd 'tailscale status --json' | ${pkgs.gnugrep}/bin/grep -o '"BackendState": "[A-Za-z]*"' | ${pkgs.coreutils}/bin/cut -d'"' -f4)
          inner=$(vmcmd "ping -c2 -W2 $HACKSPACE_IP >/dev/null 2>&1 && echo up || echo down")
          # Is the pre-auth key even visible in the VM? If the session is down AND
          # the key is missing, the re-join timer cannot possibly work and the key
          # is not the suspect: the guest's /run/secrets is a virtiofs share whose
          # directory virtiofsd opened at VM start, so an empty share means the
          # host republished it after the VM booted. On 2026-10-21 the alert blamed
          # "the pre-auth key may need replacing" for 3.5 h while the actual fault
          # was a stale share; the key was fine and was never the problem.
          key=$(vmcmd 'test -s ${config.sops.secrets.leigh_hackspace_tailscale_pre_auth_key.path} && echo present || echo missing')

          if [ -z "$backend" ]; then
            where="VM is up but ssh into it failed (tailscaled not even reachable?)"
          elif [ "$backend" != Running ] && [ "$key" = missing ]; then
            where="VM's tailscale BackendState=$backend and its pre-auth key is NOT VISIBLE in the guest (/run/secrets is empty) — the secrets virtiofs share is stale, not the key. Fix from the host: systemctl restart microvm@grafton-hackspace-client (the node key is on a disk, so this costs no re-registration unless the session is already gone)"
          elif [ "$backend" != Running ]; then
            # Usually self-healing now: hackspace-tailscale-ensure.service (in
            # the VM) re-registers within a minute of the session dropping. So
            # NeedsLogin persisting past that means the re-registration itself
            # is failing - the key is the remaining suspect, NOT its being
            # unused-at-boot. Cause seen 2026-10-16: their headscale deleted the
            # node (`404: node not found`), which logs the client out on its
            # own; check `journalctl -u tailscaled` in the VM for the reason.
            where="VM's tailscale BackendState=$backend and the 1-min re-join timer is not fixing it, although the pre-auth key IS visible in the guest - read the reason: journalctl -u tailscaled -u hackspace-tailscale-ensure in the VM (a 404 'node not found' means the hackspace's headscale deleted this node; the key is reusable)"
          elif [ "$inner" = up ]; then
            # This is the sneaky one, and what actually broke things on
            # 2026-10-14: the VM reaches the hackspace fine, but the return path
            # is gone, so grafton->leighhack is one-way. The VM advertises
            # 192.168.49.0/24, and a FRESH registration (which is what a
            # diskless VM does on every boot) starts with that route NOT enabled
            # on their headscale, so services1 has no way back to us.
            where="ONE-WAY: the VM reaches 10.3.1.1 but replies never return. The advertised subnet route 192.168.49.0/24 is not enabled on the hackspace headscale - ask them to enable it for node grafton-hackspace-client"
          else
            where="VM's tailscale is Running but the VM itself cannot reach 10.3.1.1 - the outage is on the hackspace side"
          fi
        fi

        if [ "$healthy" = 1 ]; then
          if [ "$prev" = 0 ]; then
            notify "leighhack tailnet recovered" \
              "10.3.0.0/16 and the IPv6 *.int path are reachable again via $VM_IP. Failure history: journalctl -u hackspace-tunnel-check.service"
          fi
          ${pkgs.coreutils}/bin/echo ok
          exit 0
        fi

        ${pkgs.coreutils}/bin/echo "DOWN: $where (consecutive failures: $fails)"

        # Alert after FAIL_THRESHOLD consecutive failures, then at most every RE_ALERT_SECS.
        if [ "$fails" -ge "$FAIL_THRESHOLD" ] && \
           [ $((now - last_alert)) -ge "$RE_ALERT_SECS" ]
        then
          notify "leighhack tailnet DOWN" \
            "$where

    Diagnose: sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh
    In the VM: ssh root@$VM_IP 'tailscale status; journalctl -u tailscaled -u hackspace-tailscale-ensure --since -1h'
    The VM re-joins by itself now, so a tunnel that stays down means the re-join
    itself is failing: read hackspace-tailscale-ensure's output in the VM before
    touching the key — it exits 1 naming the reason (missing key vs rejected).
    See docs/leighhack-tailscale.md before restarting anything"
          ${pkgs.coreutils}/bin/echo "$now" > "$STATE_DIR/last-alert"
          ${pkgs.coreutils}/bin/echo "alert sent"
        fi
  '';
in
{
  systemd.services.hackspace-tunnel-check = {
    description = "Check the leighhack tailscale bridge and alert if it is down";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = check;
      StateDirectory = "hackspace-tunnel-check";
      PrivateTmp = true;
    };
  };

  systemd.timers.hackspace-tunnel-check = {
    description = "Check the leighhack tailscale bridge every 2 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      Unit = "hackspace-tunnel-check.service";
      OnBootSec = "5min";
      OnUnitActiveSec = "2min";
      RandomizedDelaySec = "15s";
    };
  };
}
