# Thread border router for Matter-over-Thread devices.
#
# Radio: Sonoff ZBDongle-P (TI CC2652P10, shield marked "C2652P") flashed with
# OpenThread RCP firmware — scripts/flash-thread-rcp.sh pins the exact image
# (Koenkk ot-ti 2025.3.1, "CC1352P2_CC2652P_launchpad" build, which that repo
# lists explicitly for the SONOFF ZBDongle-P). Sonoff's own flasher only
# offers Zigbee for the CC2652P dongle; the Sonoff OT guide's "OpenThread RCP"
# entry is for the newer Dongle-PP10. RCP firmware = the stick is a dumb
# spinel-over-UART radio at 460800 8N1 (no hardware flow control); all Thread
# logic runs here in the OTBR container.
#
# Identity (verified on the live stick 2026-11-26): CP2102N USB bridge
# (10c4:ea60) with a unique serial — unlike the older CH340-bridge P revision,
# so a serial match pins this exact dongle and it may sit in ANY USB socket.
# After flashing, otbr-agent --radio-version answered "OPENTHREAD/1.4.0-Koenkk-
# 2025.3.1; CC13XX_CC26XX" — that line is the fingerprint of a healthy RCP.
#
# Host side: the official openthread/border-router image (pinned by digest).
# Its s6 otbr-agent run script reads OT_RCP_DEVICE / OT_INFRA_IF /
# OT_THREAD_IF / OT_REST_* from the environment, puts Thread state in /data
# (symlinked to /var/lib/thread), inserts its own ingress filter for
# unicast into the mesh via ip6tables, and starts otbr-agent on BOTH radio
# URLs — the UART RCP plus trel://<infra> (TREL over the LAN). It needs
# --network host and privileged so those netfilter edits land in the host
# namespace. REST listens on 127.0.0.1:8081 by default; the HA container is
# host-networked too, so Home Assistant reaches it on loopback — nothing else
# on the LAN should.
#
# Home Assistant side: add the `otbr` integration with url
# http://127.0.0.1:8081 (Settings → Integrations → OpenThread Border Router),
# the `thread` integration then appears; mark its network as preferred. The
# matter-server container (home-assistant.nix) and its BLE adapter already
# exist. Full runbook incl. the Matter commissioning steps:
# docs/thread-border-router.md
#
# journalctl -u podman-otbr -f
{
  config,
  lib,
  pkgs,
  ...
}:

let
  net = import ../networking/constants.nix;

  # CP2102N serial of OUR dongle (`ls -l /dev/serial/by-id/`, the string after
  # "Sonoff_Zigbee_3.0_USB_Dongle_Plus_"). Empty disables the service
  # entirely — that is the knob for "no radio attached", not a wrong guess:
  # matching a different CP210x would hand OTBR someone else's serial line.
  # If the stick is ever swapped for another, update this string.
  rcpSerial = "d01311ed57c9eb1198a28b4f1d69213e";
  rcpDev = "/dev/otbr-rcp";

  # Kernel-managed udev symlink for this exact stick (verified name on
  # grafton-router). The path unit watches THIS, never rcpDev: while the
  # privileged container runs, repeated create/change events materialize on
  # /dev/otbr-rcp with no udev event and no visible inode/mtime change
  # (measured 2026-11-27 — plug fired every ~7 s with the container up, zero
  # kernel uevents, symlink inode frozen). Whatever crun/podman does to the
  # resolved node, nothing ever touches /dev/serial/by-id.
  rcpById = "/dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_${rcpSerial}-if00-port0";

  # docker.io/openthread/border-router:latest as of 2026-11-24 (re-pin with
  # nix shell nixpkgs#skopeo --command skopeo inspect
  #   docker://docker.io/openthread/border-router:latest)
  otbrImage = "docker.io/openthread/border-router@sha256:ccab33a1aa3965cd7aec18bbf5869de1e88b43946e33256899df4f6e62180cba";

  stateDir = "/srv/otbr";
in
{
  services.udev.extraRules = lib.optionalString (rcpSerial != "") ''
    # Sonoff ZBDongle-P running OpenThread RCP → ${rcpDev} (services/otbr.nix)
    SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", ATTRS{serial}=="${rcpSerial}", SYMLINK+="${lib.strings.removePrefix "/dev/" rcpDev}", MODE="0660"
  '';

  virtualisation.oci-containers.containers = lib.optionalAttrs (rcpSerial != "") {
    otbr = {
      hostname = "otbr";
      image = otbrImage;
      autoStart = true;
      volumes = [
        # The image's agent run script does `ln -sft /var/lib /data/thread`,
        # so the Thread network dataset (network key, BR id, on-mesh prefix)
        # persists in ${stateDir}/thread — covered by the borg backup-srv job
        # (it archives all of /srv). Losing this = recreating the mesh.
        "${stateDir}:/data"
        "/etc/localtime:/etc/localtime:ro"
      ];
      devices = [
        "/dev/net/tun"
      ];
      environment = {
        TZ = "Europe/London";
        # 6 = Info; 7 (Debug) floods — the image default is 7.
        OT_LOG_LEVEL = "6";
        # TI ot_rcp firmware: spinel HDLC over UART at 460800, no HW flow
        # control (otbr has it OFF unless the URL adds uart-hw-flow-control).
        OT_RCP_DEVICE = "spinel+hdlc+uart://${rcpDev}?uart-baudrate=460800";
        OT_INFRA_IF = net.LAN_INTERFACE;
        OT_THREAD_IF = "wpan0";
        # HA + matter-server containers are --network host, so loopback is
        # enough; keep the REST API off the LAN.
        OT_REST_LISTEN_ADDR = "127.0.0.1";
        OT_REST_LISTEN_PORT = "8081";
      };
      # ⚠️ `--device` with a SYMLINK source is resolved by podman: bare
      # --device=/dev/otbr-rcp lands in the container as /dev/ttyUSBn and the
      # agent ENOENTs on the radio URL (crash loop, observed 2026-11-27).
      # The explicit :target form is required — verified by podman run test.
      extraOptions = [
        "--network"
        "host"
        "--privileged"
        "--device=${rcpDev}:${rcpDev}"
      ];
    };
  };

  # Do NOT let the container unit start during activation: the first switch failed the
  # whole `switch-to-configuration` run when podman errored on a missing device, and the
  # auto-rollback timer then rebooted the router off the half-switched generation five
  # minutes later. Instead it is pulled exclusively by the path unit below, so activation
  # can never fail on radio presence. Restart=always still covers transient create
  # failures at runtime. (Note the whole sets are optionalAttrs-gated: per-name
  # `optionalAttrs` would still register default-only empty units when disabled.)
  systemd.services = lib.optionalAttrs (rcpSerial != "") {
    podman-otbr = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = lib.mkForce [ ];
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = 10;
      };
    };

    # Upstream OTBR (unlike the HAOS add-on) does NOT form a network when the
    # persisted dataset is empty — an unplugged-then-plugged fresh stick sits
    # at state "disabled" forever. This oneshot waits for otbr-agent, then
    # forms a network exactly when none exists (idempotent: greps networkkey
    # out of the live dataset). Always exits 0 — formation trouble must never
    # take the radio unit down with it. TimeoutStartSec is explicit because
    # the wait loop is ~60 s of headroom and must stay under systemd's
    # default 90 s start timeout (a unit killed mid-form looks like a
    # formation failure but is a timeout artefact).
    otbr-form = {
      unitConfig.After = [ "podman-otbr.service" ];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = 150;
        ExecStart = pkgs.writeShellScript "otbr-form" ''
          set -u
          podman="${pkgs.podman}/bin/podman"
          for _ in $(seq 30); do
            sleep 2
            "$podman" exec otbr ot-ctl state >/dev/null 2>&1 && break
          done
          if ! "$podman" exec otbr ot-ctl dataset info active 2>/dev/null | grep -q networkkey; then
            "$podman" exec otbr sh -c 'ot-ctl dataset init new >/dev/null && ot-ctl dataset commit active >/dev/null && ot-ctl ifconfig up >/dev/null && ot-ctl thread start >/dev/null' || true
          fi
          exit 0
        '';
      };
    };

    # Device-driven lifecycle: fires at boot when the stick is attached, and
    # on every re-seat (the by-id symlink is removed/recreated by udev).
    # PLAIN restart, never try-restart: try-restart is a silent no-op on an
    # inactive unit, and by design podman-otbr is always inactive until the
    # first event (observed 2026-11-27 — every event did nothing, and five
    # coalesced no-ops tripped the start limit). Restart also recreates the
    # container on re-seat, which matters because podman binds the resolved
    # inode, not the symlink. StartLimitIntervalSec=0: one physical plug
    # emits several change events; bursty triggers are expected, not a fault.
    # The device-generation guard (stat inode:ctime vs /run state) makes
    # repeat events on the SAME stick a no-op, so even a spurious trigger
    # storm cannot churn the container — only a genuinely new device node or
    # a downed unit causes a restart. The udevadm self-trigger covers the one
    # window where the symlink lags: right after the first switch that ships
    # the udev rule, the already-running device predates it.
    otbr-rcp-plug = {
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "otbr-rcp-plug" ''
          set -u
          systemd="${pkgs.systemd}/bin"
          byid="${rcpById}"
          dev=""
          for _ in $(seq 20); do
            dev=$(readlink -f "$byid" 2>/dev/null || true)
            [ -n "$dev" ] && break
            sleep 0.5
          done
          if [ -n "$dev" ]; then
            "$systemd/udevadm" trigger --action=change "$dev" 2>/dev/null || true
          fi
          for _ in $(seq 20); do
            [ -e ${rcpDev} ] && break
            sleep 0.5
          done
          state=/run/otbr-rcp-plug.state
          cur=$(stat -c "%i:%Z" ${rcpDev} 2>/dev/null || echo gone)
          if [ "$cur" != gone ] \
            && [ "$(cat "$state" 2>/dev/null || echo none)" = "$cur" ] \
            && "$systemd/systemctl" is-active --quiet podman-otbr.service; then
            exit 0
          fi
          echo "$cur" >"$state"
          exec "$systemd/systemctl" restart podman-otbr.service otbr-form.service
        '';
      };
    };
  };

  systemd.paths = lib.optionalAttrs (rcpSerial != "") {
    otbr-rcp = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExistsGlob = rcpById;
        PathChanged = rcpById;
        Unit = "otbr-rcp-plug.service";
      };
    };
  };

  systemd.tmpfiles.settings = lib.optionalAttrs (rcpSerial != "") {
    "10-otbr" = {
      ${stateDir} = {
        d = {
          user = "root";
          group = "users";
          mode = "0755";
        };
      };
    };
  };
}
