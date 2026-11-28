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
    # a third inverter means another id here plus its MR_<ID>_* settings, and a
    # driver if it is a new make/model. Its MR_<ID>_PORT becomes a discovery
    # candidate automatically; an inverter of a make/model the relay has never
    # seen also needs its meter polls written down (MR_<ID>_METER_POLL, measured
    # with crates/meter-relay-rs/scripts/capture-serial.py) or discovery cannot
    # tell its meter line from another inverter's.
    MR_INVERTERS = "solis,solax,solis2";
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

    # --- Solis 2: the second S6 hybrid, plumbed but INERT (2026-11-27) -----
    # Wired and verified on the wires: stats bus answers at slave 3 (battery
    # 48.9 V, same 33xxx register layout as its sibling), and its meter port
    # hammers this line for an Eastron SDM630-style three-phase meter
    # (fc4 0x00/0x0C/0x18/0x34, the totals block at ~100 Hz while hunting).
    # It is served the honest grid reading in the sdm630 dialect, but the
    # NUDGE LIMIT is the kill switch: the PID's only authority over an
    # inverter is the nudge on the phantom reading, and zero nudge means the
    # relay observes this inverter without ever steering it. That is
    # deliberate — its AC wiring is temporary and cannot carry the currents
    # a charge/discharge loop would command, and it has no battery CAN yet.
    # Arming later is exactly: raise MR_SOLIS2_NUDGE_LIMIT and the MAX_* /
    # CHARGE_POWER budgets to the intended values, after confirming its
    # meter-power sign convention (REVERSE below follows the vendor doc's
    # "+ = to grid", unverified on this model until the arming test).
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
    MR_SOLIS2_REVERSE = "true"; # vendor convention "+ = to grid"; confirm at first window
    MR_SOLIS2_KP = "0.3";
    # ARMED CHARGE-ONLY, but found to be a PHANTOM on the night of 2026-11-28:
    # the unit is still in its off-grid/bypass commissioning state, so it reads
    # our emulated meter and does nothing with it — and its battery registers
    # are the BMS/CAN stream, not a measurement of this inverter. The balance
    # (meter_power - house - solis - solax) leaves 0 W for this unit on every
    # sample, while its "battery power" tracks solis1's DC current. Do not read
    # its position on the dashboard as work done: `inverting_power`
    # (33151-52) is the honest per-unit number, and 33149's sign flaps with
    # 33135. MAX_DISCHARGE stays 0 while it is uncommissioned: if it ever does
    # go on-grid with an unverified REVERSE, the wrong way to move is discharge,
    # and that door is physically locked from the relay's side. Commission it
    # (grid standard, storage mode, meter/CT setting) before judging the loop;
    # its own Max-Grid-Charge-Current is the hardware bound (~30 A set for now).
    MR_SOLIS2_NUDGE_LIMIT = "1500";
    MR_SOLIS2_HA_PREFIX = "solis2";
    MR_SOLIS2_MAX_DISCHARGE = "0";
    MR_SOLIS2_MAX_CHARGE = "1500";
    MR_SOLIS2_SLEW = "1500";
    MR_SOLIS2_CHARGE_POWER = "1500";
    MR_SOLIS2_MIN_SOC = "20";
    MR_SOLIS2_MAX_SOC = "95";
    MR_SOLIS2_ABSORB_SURPLUS = "false";

    # --- Dashboard ----------------------------------------------------------
    # MR_WEB_DIR is set by the package wrapper to the bundled dashboard in the
    # store; don't set it here or it will shadow the store path.
    MR_WEB_PORT = "8484";

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
