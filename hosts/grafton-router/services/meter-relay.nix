{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  inherit (import ../../../utils/convert.nix { inherit lib; }) convertToEnvFile;

  # Built from crates/meter-relay-rs via its nix/package.nix (folded into this
  # repo's flake — no separate meter-relay-rs input any more): a self-contained
  # Rust binary — serial grid meter, Modbus TCP to the inverters, PID load
  # balancing, HA/Influx publishing — with the Solid.js dashboard bundled in and
  # served from the store (the wrapper sets MR_WEB_DIR). It builds against this
  # repo's nixpkgs; crane slices the cargo dependency graph (see the crane input
  # in flake.nix).
  meterRelay = pkgs.callPackage ../../../crates/meter-relay-rs/nix/package.nix {
    craneLib = inputs.crane.mkLib pkgs;
  };

  # ---------------------------------------------------------------------------
  # The entire relay configuration, declaratively.
  #
  # This used to live in a gitignored .env inside the checkout, which meant the
  # relay's *actual* configuration was invisible to review, could not be diffed
  # against what this file claimed, and could only be changed by hand on the
  # host. It is a NixOS setting now: to change how the relay behaves, change
  # this file and rebuild. The only thing that still comes from elsewhere is the
  # two secrets, which arrive through sops (below).
  #
  # Values are strings because that is what a process environment is. Variables
  # deliberately *not* listed here fall back to the code's own defaults
  # (`AllocatorConfig::default()`, `driver_defaults()` and `Config::from_env()`
  # in meter-relay-rs), so this file states the decisions rather than mirroring
  # every constant.
  # ---------------------------------------------------------------------------
  plant = {
    # --- The plant ----------------------------------------------------------
    # Priority order: entry 0 is the primary actuator, the rest are the reserve
    # group — asked only for what the entries before them cannot cover, in both
    # directions (the reserve is charged from the surplus the main bank's taper
    # cannot take, and discharged for demand the main bank cannot meet). Adding
    # A third inverter means another id here plus its MR_<ID>_* settings, and a
    # driver if it is a new make/model. Its MR_<ID>_PORT becomes a discovery
    # candidate automatically; an inverter of a make/model the relay has never
    # seen also needs its meter polls written down (MR_<ID>_METER_POLL, measured
    # with crates/meter-relay-rs/scripts/capture-serial.py) or discovery cannot
    # tell its meter line from another inverter's.
    # The order is the priority order, and MR_<ID>_PRIMARY splits it into a
    # primary group and a reserve: both Solises are primary (they DIVIDE the
    # discharge demand between them, so neither carries an evening alone) and
    # the Solax is the only reserve, waking past the pair's combined authority.
    MR_INVERTERS = "solis,solis2,solax";
    MR_INVERTER_HOST = "192.168.49.30";

    # --- Which endpoint is which (startup auto-detection) --------------------
    # The inverter-pi bridges three CH340 USB adapters plus (since
    # 2026-11-27, the second Solis's meter line) one FTDI FT232R onto the TCP
    # ports below, and the grid meter hangs off a USB adapter on THIS host. None of those names are identities: the pi's adapters have no
    # serial numbers, so the kernel's ttyUSB0..2 mapping — and therefore the
    # port-to-inverter mapping — shuffles across reboots, and a meter adapter
    # can (did, 2026-11-27: fourteen seconds after discovery confirmed it as
    # the meter) die on the USB bus and take its by-id path with it. The
    # MR_*_PORT values below and MR_SERIAL_DEVICE are therefore *hints*, and
    # at startup the relay works out which endpoint really is which — by
    # listening for each inverter's own meter polls, then probing the
    # endpoints that stayed silent (the stats bus and the USB grid meter
    # answer; a line with an inverter polling on it is never probed at all).
    # Local serial candidates are everything the kernel lists under
    # /dev/serial/by-id and by-path, not just the one named, so a meter
    # re-plugged into a different adapter is found there. See
    # crates/meter-relay-rs/src/discovery.rs and .../src/serial.rs.
    MR_DISCOVERY = "auto";
    # Never probe the Thread border router's radio — otbr-agent reads and
    # writes that port live, and a Modbus probe stealing a frame would break
    # the mesh quietly. The exclusion names the *link* that
    # hosts/grafton-router/services/otbr.nix creates for the stick (by its
    # unique serial), not the adapter, so a radio swap is still covered and
    # no adapter that could one day carry the meter is ever vetoed.
    MR_SERIAL_EXCLUDE = "/dev/otbr-rcp";
    # Refuse to start rather than serve a meter line whose polarity is a guess:
    # the Solis reads its meter reversed, so answering its polls un-negated
    # would drive the plant the wrong way. An endpoint that cannot be placed is
    # reported on the diagnostics page (/#/diagnostics) instead, and `curl
    # /api/connections` shows the same thing.
    MR_DISCOVERY_STRICT = "true";
    # And once running: if the grid meter's device node has been *gone from the
    # bus* for a whole minute (MR_METER_GONE_AFTER_MS), the relay exits and
    # systemd re-runs startup discovery rather than keep driving the plant from
    # the frozen last reading — which is exactly what nine hours of 2026-11-27
    # proved wrong.
    # Measured on this plant: four endpoints, settled in about 3 s.
    MR_DISCOVERY_LISTEN_MS = "3000";

    MR_STATS_PORT = "2002";

    # --- Objective ----------------------------------------------------------
    # Grid power to hold, in the meter's own sign convention (positive =
    # import), so "+50" means "keep about 50 W of export".
    MR_METER_TARGET_POWER = "50";

    # --- Central loop -------------------------------------------------------
    MR_PID_KP = "0.9";
    MR_PID_KI = "0.3";
    MR_PID_KD = "0"; # derivative on measurement; measured to buy nothing
    MR_CONTROL_DEADBAND = "20";

    # --- Reserve wake/release hysteresis (plant-level, not per inverter) -----
    MR_RESERVE_WAKE_ERROR = "120";
    MR_RESERVE_WAKE_DELAY_MS = "1500";
    MR_RESERVE_RELEASE_MARGIN = "250";
    MR_RESERVE_RELEASE_DELAY_MS = "30000";

    # --- Solis: the large main bank, primary actuator -----------------------
    # Primary group member 1 of 2 (PRIMARY defaults to the first entry; written
    # out here because the grouping is the plant's whole design).
    MR_SOLIS_PRIMARY = "true";
    MR_SOLIS_DRIVER = "solis";
    MR_SOLIS_PORT = "2000";
    MR_SOLIS_SLAVE = "2";
    MR_SOLIS_KP = "0.3"; # gentle: it does not like abrupt commands
    MR_SOLIS_NUDGE_LIMIT = "3600";
    MR_SOLIS_REVERSE = "true"; # reads the phantom meter negated
    MR_SOLIS_HA_PREFIX = "inverter";
    MR_SOLIS_MAX_DISCHARGE = "3600";
    MR_SOLIS_MAX_CHARGE = "3600";
    MR_SOLIS_SLEW = "4000";
    MR_SOLIS_CHARGE_POWER = "4000";
    MR_SOLIS_ABSORB_SURPLUS = "true"; # takes the surplus before the reserve does

    # --- Solax: the small reserve -------------------------------------------
    # The only reserve: on line when the two Solises together run out of
    # authority, or to soak up surplus the main banks cannot take.
    MR_SOLAX_PRIMARY = "false";
    MR_SOLAX_DRIVER = "solax";
    MR_SOLAX_PORT = "2001";
    MR_SOLAX_SLAVE = "1";
    MR_SOLAX_KP = "0.5";
    MR_SOLAX_NUDGE_LIMIT = "3000";
    MR_SOLAX_REVERSE = "false";
    MR_SOLAX_HA_PREFIX = "solax";
    MR_SOLAX_MAX_DISCHARGE = "1500";
    # Rated ~2 kW (the TypeScript service noted the same). The 1 kW default left
    # roughly a kilowatt of absorbable midday surplus going to the grid whenever
    # the main bank was full — see CONTROL-DESIGN.md §1.
    MR_SOLAX_MAX_CHARGE = "2000";
    MR_SOLAX_SLEW = "1200";
    MR_SOLAX_CHARGE_POWER = "1000";
    MR_SOLAX_MIN_SOC = "15"; # not discharged at or below this %
    MR_SOLAX_MAX_SOC = "95"; # not charged at or above this %
    MR_SOLAX_ABSORB_SURPLUS = "true";

    # --- Solis 2: the second S6 hybrid, in the PRIMARY GROUP (2026-11-28) ---
    # Wired and verified on the wires: stats bus answers at slave 3 (battery
    # 48.9 V, same 33xxx register layout as its sibling), and its meter port
    # hammers this line for an Eastron SDM630-style three-phase meter
    # (fc4 0x00/0x0C/0x18/0x34, the totals block at ~100 Hz while hunting).
    # It is served the honest grid reading in the sdm630 dialect, and the
    # NUDGE LIMIT is its steering authority: the PID's only power over an
    # inverter is the nudge on that emulated reading. The unit was commissioned
    # on-grid on 2026-11-28 (Self-Use + TOU + Reserve + allow-grid-charge, i.e.
    # 43110/33132 = 51, matching its sibling — the blocker had been Solis
    # 43110 bit 2, the Off-Grid *switch* inside the Off-grid page) and does
    # follow the meter it is shown. REVERSE is proven closed-loop by the grid
    # meter, not by the vendor doc.
    #
    # 2026-11-28 afternoon — what that unit's own MENU must say, because the
    # relay cannot set any of it: **Backup Supply OFF** (43111 = 0) and,
    # therefore, `43110 = 33` (Self-Use + Allow Grid Charge, no reserve, no
    # TOU). With Backup Supply ON the factory Reserved SOC (43024 = 80 %)
    # applies, and a pack below 80 % charges at the AC limit the instant a mode
    # allows grid import — it ignores every target while doing it. 43024 and
    # 43027 are read-only over Modbus. Backup off removes the floor; 33 then
    # charges AND discharges under the relay's control (pins −1500 W and
    # +2500 W both converged, see docs/meter-relay.md). Backup output is
    # deliberately not provided by this unit.
    MR_SOLIS2_DRIVER = "solis";
    MR_SOLIS2_PORT = "2003";
    MR_SOLIS2_SLAVE = "3";
    MR_SOLIS2_METER_DIALECT = "sdm630";
    # The S6's poll vocabulary GROWS with its state: hunting cycles
    # 0x00/0x0C/0x18/0x34-n6; locked-on it hammered 0x0C n6 at ~110 Hz; in
    # steady state (observed the first night, 00:34) it adds per-phase PF
    # (0x1E n6) and a widened totals read (0x34 n10). Discovery only needs
    # ANY observed pattern to match, so list every state's vocabulary —
    # a fingerprint that lags the inverter's phases locks strict mode out
    # of the whole plant (it did, 2026-11-28 00:34, mid Go-window).
    MR_SOLIS2_METER_POLL = "4:0:6,4:12:6,4:18:6,4:30:6,4:52:6,4:52:10";
    MR_SOLIS2_REVERSE = "true"; # "+ = to grid"; proven closed-loop 2026-11-28
    MR_SOLIS2_KP = "0.3";
    # MEASURE IT BY THE AC PORT. Its battery registers are the BMS/CAN stream,
    # not a measurement of this inverter — re-probed on the bus 2026-11-28 with
    # the unit idle and its sibling discharging 1.7 kW: 33134 read 36.7 A (=
    # 33142, the BMS's bank current, to 0.1 A) while 33151 read 0 W, and 33149
    # read 1919 W = its own 52.3 V times that borrowed current, while solis1's
    # 33134 (37.4 A) matched its OWN 1963 W / 52.5 V. So solis1's block is a
    # shunt and solis2's is the bank; 33149's sign also comes from 33135, which
    # moves. Driven by that figure the per-inverter loop was positive feedback
    # and the unit limit-cycled ±3.9 kW (docs/meter-relay.md). 33151 is honest,
    # and complete for this unit: no PV strings, no load on its output, so every
    # AC watt is a battery watt (less ~8 % conversion). See PowerSource in
    # inverters.rs for the sign guarantees that make the switch safe.
    # The phantom is still published (sensor.solis2_battery_power) for
    # diagnostics and as the labelled "battery register" dashboard row.
    # NUDGE LIMIT is the inner loop's ONLY lever, and it clamps the command: at
    # 1500 W the unit could never be told to do more, so "it caps near 1500 W"
    # was partly our own doing, not the inverter's. In the primary group its
    # share of an evening demand exceeds that, so the limit is set to the unit's
    # rating like its sibling's (solis 3600, solax 3000): a command the loop
    # cannot deliver shows up as the authority learner collapsing this unit's
    # limit to the 150 W floor — last night's signature — so the clamp must sit
    # above the allocator's ceiling, not below it.
    MR_SOLIS2_NUDGE_LIMIT = "3000";
    MR_SOLIS2_POWER_SOURCE = "ac";
    MR_SOLIS2_HA_PREFIX = "solis2";
    # PRIMARY GROUP with solis1: both Solises are on line for every discharge
    # demand and DIVIDE it in proportion to their authority (3.6:3.0), so an
    # ordinary evening load is shared instead of wearing one unit down. The
    # Solax is now the only reserve and wakes past the pair's combined
    # authority (~6.6 kW) rather than past one unit's.
    # The ceilings are this unit's rating (3 kW model — owner's spec: the bus
    # publishes no rated-power register, so this number is the plate, not a
    # measurement). The limits that actually bind are learned per unit from what
    # it delivers, the BMS's 81.0 A CCL/DCL broadcast to both (33143/33144 =
    # 810, identical — 4.2 kW at 52 V, so neither unit is BMS-capped at its
    # rating), and this unit's own Max-Grid-Charge-Current, read off the wire as
    # 30 A at 43074/33247 against solis1's 99 A — i.e. ~6.9 kW, not the
    # constraint it was thought to be.
    MR_SOLIS2_PRIMARY = "true";
    MR_SOLIS2_MAX_DISCHARGE = "3000";
    MR_SOLIS2_MAX_CHARGE = "3000";
    MR_SOLIS2_SLEW = "1500";
    MR_SOLIS2_CHARGE_POWER = "3000";
    MR_SOLIS2_MIN_SOC = "20";
    MR_SOLIS2_MAX_SOC = "95";
    # Takes surplus too, so midday charging is split across both banks' leads
    # rather than tapering one unit while the other sits idle.
    MR_SOLIS2_ABSORB_SURPLUS = "true";

    # --- Dashboard ----------------------------------------------------------
    # MR_WEB_DIR is set by the package wrapper to the bundled dashboard in the
    # store; don't set it here or it will shadow the store path.
    MR_WEB_PORT = "8484";

    # Raw Modbus passthrough (`/api/modbus`) rides the stats bus the poll loop
    # already owns, so looking at — or nudging — a register no longer costs a
    # service restart (which drops the emulated meter lines and the plant's
    # setpoint while you are looking at it). Reads are always allowed; writes
    # are opt-in because a raw FC6 can change an inverter's storage mode, which
    # is how the S6's latched meter rejection was cleared on 2026-11-28.
    MR_MODBUS_WRITE_ENABLED = "true";

    # --- Publishing ---------------------------------------------------------
    MR_HOME_ASSISTANT_API = "http://hass.grafton.lan:8123";
    MR_INFLUXDB_URL = "http://192.168.49.1:8086";

    # --- Shouting (alerts.rs) ------------------------------------------------
    # From inside a running relay: Home Assistant `notify` services to push
    # to (the companion apps on both phones) when the plant should not be
    # trusted — a stale grid meter feed or a dead link. New problems push,
    # cleared problems push, and while anything is active the whole list
    # re-shouts every 30 min (MR_ALERT_REPEAT_MS); MR_ALERT_GRACE_MS (60 s)
    # keeps reconnect backoff from paging anyone. The same state lives on
    # sensor.meter_relay_alerts ("ok" or the problem list) for automations,
    # and MR_ALERT_WEBHOOK_URL (unset) can add ntfy or an HA webhook on top.
    # A relay that cannot START cannot shout — startup discovery refuses
    # exactly when the meter answers nowhere — so the meter-relay-alert unit
    # below is the systemd-side twin of this setting.
    MR_ALERT_HA_SERVICES = "notify.mobile_app_oneplus_7t_pro,notify.mobile_app_pixel_8_pro";
  };
in
{
  # Rust port of the former TypeScript meter-relay. Same job, same ports: reads
  # the grid meter over serial, re-serves it to the inverters on
  # 192.168.49.30:2000/2001/2003 (stats on :2002) and nudges them with PIDs so grid
  # export tracks MR_METER_TARGET_POWER. Serves a live web dashboard on :8484
  # (the old Express app's /stats port; /stats is kept for compatibility, plus
  # /api/status, /api/history, /api/events SSE and /api/connections). The
  # dashboard's second page, /#/diagnostics, shows what startup discovery
  # decided each serial endpoint is, with per-connection health and error rates.
  #
  #   sudo systemctl restart meter-relay     # picks up a config change
  #   journalctl -u meter-relay -f
  #
  # After any change to the physical wiring, ask what the relay can see without
  # starting it (it needs the unit's own environment; stop the service first —
  # it holds those ports):
  #
  #   sudo systemctl stop meter-relay
  #   sudo bash -c 'set -a; . /run/secrets/rendered/meter-relay.env; set +a; \
  #     MR_DISCOVERY_ONLY=1 $(systemctl show -p ExecStart --value meter-relay \
  #       | grep -o "/nix/store/[^ ]*meter-relay$")'
  #   sudo systemctl start meter-relay
  #
  # There is no WorkingDirectory: the configuration arrives in the environment
  # (below), not from a file in the checkout, so the unit no longer depends on
  # the source tree being present.
  systemd.services.meter-relay = {
    serviceConfig = {
      Type = "simple";
      ExecStart = lib.getExe meterRelay;

      # Shared with meter-relay-alert.service: the outage marker that unit
      # writes is what turns this process's first clean run into a
      # "recovered" push instead of silence.
      StateDirectory = "meter-relay-alert";

      # The plant, as declared above. Non-secret, so it is deliberately visible
      # in `systemctl show meter-relay` and in the store for review.
      Environment = lib.mapAttrsToList (name: value: "${name}=${value}") plant;

      # Secrets only. Rendered by sops at activation, so they never reach the
      # Nix store. systemd gives EnvironmentFile precedence over Environment,
      # and nothing here overlaps with the plant above.
      EnvironmentFile = config.sops.templates."meter-relay.env".path;

      Restart = "always";
      RestartSec = 5;
    };
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    # The relay alerts from inside for problems it can SEE (alerts.rs). The
    # failure it cannot report is its own: startup discovery refuses (strict)
    # exactly when the grid meter answers on no port, and a relay in that
    # restart loop serves nothing and shouts nothing. systemd sees it —
    # OnFailure fires on every exit — and this unit pushes the same Home
    # Assistant notifies the in-process alerter uses.
    unitConfig.OnFailure = [ "meter-relay-alert.service" ];
  };

  # See meter-relay.service's OnFailure: a oneshot that pushes "the relay
  # itself has failed" over Home Assistant notify, rate-limited to one push
  # per ten minutes so a strict-discovery crash-loop (one exit per ~15 s) is
  # one bad morning, not a thousand notifications. It reads the relay's own
  # rendered environment (the sops template) for the HA URL and token, and
  # leaves the outage marker the relay deletes when it is back and clean.
  systemd.services.meter-relay-alert = {
    description = "Push a Home Assistant notification that meter-relay has failed";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "meter-relay-alert";
      # The HA URL + token come from the same sops template the relay uses,
      # and MR_ALERT_HA_SERVICES from the generated non-secret twin below —
      # `plant` stays the one source of truth for both processes.
      EnvironmentFile = [
        config.sops.templates."meter-relay.env".path
        config.environment.etc."meter-relay/alert.env".source
      ];
    };
    path = [
      pkgs.curl
      pkgs.jq
    ];
    script = # !/bin/sh
      ''
        set -u
        state=/var/lib/meter-relay-alert
        touch "$state/outage"

        now=$(date +%s)
        last=$(cat "$state/last" 2>/dev/null || echo 0)
        [ $((now - last)) -lt 600 ] && exit 0
        echo "$now" > "$state/last"

        result=$(systemctl show meter-relay -p Result -p ExecMainStatus --value | paste -sd/)
        recent=$(journalctl -u meter-relay -n 3 --no-pager -o cat | tr '\n' ' ' | cut -c1-280)
        message="meter-relay has FAILED on grafton-router (''${result}). Recent: ''${recent}"

        if [ -z "''${MR_ALERT_HA_SERVICES:-}" ] || [ -z "''${MR_HOME_ASSISTANT_API:-}" ]; then
          echo "missing MR_ALERT_HA_SERVICES or MR_HOME_ASSISTANT_API; outage marker written, no push" >&2
          exit 0
        fi
        IFS=',' read -r -a services <<< "$MR_ALERT_HA_SERVICES"
        for service in "''${services[@]}"; do
          service="''${service#notify.}"
          [ -z "$service" ] && continue
          curl -sS -m 5 -X POST \
            -H "Authorization: Bearer ''${MR_HOME_ASSISTANT_BEARER_TOKEN}" \
            -H 'content-type: application/json' \
            -d "$(jq -Rn --arg message "$message" '{message: $message}')" \
            "''${MR_HOME_ASSISTANT_API}/api/services/notify/''${service}" >/dev/null || true
        done
      '';
  };

  # A wedged relay is worse than a dead one, because systemd cannot see it.
  # Measured 2026-11-28 11:34: one runtime worker pinned a core, the HTTP accept
  # loop stopped (connections piling up in the listen backlog) and the process
  # logged nothing — `systemctl status` said active, the plant would have lost
  # its emulated meter lines for as long as nobody looked. This probes the
  # dashboard AND the control-loop timestamp (so a alive-but-not-controlling
  # relay is caught too), and restarts the unit after two consecutive bad
  # probes. It is a separate unit on purpose: it must not share the fate of the
  # thing it watches, and it stays out of the way of a deploy, during which the
  # relay is briefly inactive and `is-active` is what decides.
  systemd.services.meter-relay-watchdog = {
    description = "Probe meter-relay and restart it if it has stopped working";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "meter-relay-watchdog";
      EnvironmentFile = [
        config.sops.templates."meter-relay.env".path
        config.environment.etc."meter-relay/alert.env".source
      ];
    };
    path = [
      pkgs.curl
      pkgs.jq
      pkgs.systemd
    ];
    script = # !/bin/sh
      ''
        set -u
        state=/var/lib/meter-relay-watchdog
        url=http://127.0.0.1:${plant.MR_WEB_PORT}/api/status

        body=$(curl -fsS --max-time 5 "$url" 2>/dev/null) || body=
        ts=$(printf '%s' "$body" | jq -r '.ts // empty' 2>/dev/null) || ts=
        now=$(($(date +%s%3N)))
        fresh=0
        case "''${ts}" in
          *[!0-9]*) : ;;
          "") : ;;
          *) [ $((now - ts)) -lt 20000 ] && fresh=1 ;;
        esac

        if [ "$fresh" = 1 ]; then
          rm -f "$state/failures"
          exit 0
        fi

        failures=$(($(cat "$state/failures" 2>/dev/null || echo 0) + 1))
        echo "$failures" > "$state/failures"

        if [ "$failures" -lt 2 ]; then
          echo "meter-relay is not answering properly (probe $failures of 2): body=''${body:0:120}' ts=''${ts:-none}" >&2
          exit 0
        fi

        # Failed starts are systemd's business (Restart=always + OnFailure); a
        # wedge is this unit's. Never restart something that is not running.
        if ! systemctl is-active --quiet meter-relay; then
          echo "meter-relay is not active; leaving restart to systemd" >&2
          rm -f "$state/failures"
          exit 0
        fi

        age=-1
        case "''${ts}" in
          *[!0-9]*) : ;;
          "") : ;;
          *) age=$((now - ts)) ;;
        esac
        message="meter-relay on grafton-router is wedged (dashboard answered ''${#body} bytes, control loop ''${age} ms stale) — restarting it now"
        echo "$message" >&2
        if [ -n "''${MR_ALERT_HA_SERVICES:-}" ] && [ -n "''${MR_HOME_ASSISTANT_API:-}" ]; then
          IFS=',' read -r -a services <<< "$MR_ALERT_HA_SERVICES"
          for service in "''${services[@]}"; do
            service="''${service#notify.}"
            [ -z "$service" ] && continue
            curl -sS -m 5 -X POST \
              -H "Authorization: Bearer ''${MR_HOME_ASSISTANT_BEARER_TOKEN}" \
              -H 'content-type: application/json' \
              -d "$(jq -Rn --arg message "$message" '{message: $message}')" \
              "''${MR_HOME_ASSISTANT_API}/api/services/notify/''${service}" >/dev/null || true
          done
        fi

        systemctl restart meter-relay
        rm -f "$state/failures"
      '';
  };

  systemd.timers.meter-relay-watchdog = {
    description = "Probe meter-relay every 30 s";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "30s";
    };
  };

  # The relay's Home Assistant token is the shared long-lived API token already
  # in sops (`home_assistant_token`, also used by the speech-to-phrase
  # container) — verified to be byte-identical to what the relay was reading out
  # of its .env, so there is deliberately no second copy to drift. The InfluxDB
  # token is the relay's own: InfluxDB issues one per client, and sops is now the
  # only place it is recorded.
  sops.secrets.meter_relay_influxdb_token = { };

  sops.templates."meter-relay.env".content = convertToEnvFile {
    MR_HOME_ASSISTANT_BEARER_TOKEN = "${config.sops.placeholder.home_assistant_token}";
    MR_INFLUXDB_TOKEN = "${config.sops.placeholder.meter_relay_influxdb_token}";
  };

  # The non-secret half of that EnvironmentFile: the alert knobs — and the
  # HA API URL they aim at — taken from `plant` above, so meter-relay-alert
  # .service (which runs with no relay process to inherit from) pushes to
  # the same notify services the relay itself shouts at. Derived from
  # `plant` — there is no second copy to drift.
  environment.etc."meter-relay/alert.env".text = convertToEnvFile (
    lib.filterAttrs (name: _: lib.hasPrefix "MR_ALERT_" name || name == "MR_HOME_ASSISTANT_API") plant
  );
}
