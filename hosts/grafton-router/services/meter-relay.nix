{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  inherit (import ../../../utils/convert.nix { inherit lib; }) convertToEnvFile;

  # Built from /home/cjdell/Projects/meter-relay-rs via its own flake (see the
  # meter-relay-rs input in flake.nix): a self-contained Rust binary — serial
  # grid meter, Modbus TCP to the inverters, PID load balancing, HA/Influx
  # publishing — with the Solid.js dashboard bundled in and served from the
  # store (the wrapper sets MR_WEB_DIR).
  meterRelay = inputs.meter-relay-rs.packages.${pkgs.hostPlatform.system}.default;

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
    # driver if it is a new make/model.
    MR_INVERTERS = "solis,solax";
    MR_INVERTER_HOST = "192.168.49.30";
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

    # --- Dashboard ----------------------------------------------------------
    # MR_WEB_DIR is set by the package wrapper to the bundled dashboard in the
    # store; don't set it here or it will shadow the store path.
    MR_WEB_PORT = "8484";

    # --- Publishing ---------------------------------------------------------
    MR_HOME_ASSISTANT_API = "http://hass.grafton.lan:8123";
    MR_INFLUXDB_URL = "http://192.168.49.1:8086";
  };
in
{
  # Rust port of the former TypeScript meter-relay. Same job, same ports: reads
  # the grid meter over serial, re-serves it to the inverters on
  # 192.168.49.30:2000/2001 (stats on :2002) and nudges them with PIDs so grid
  # export tracks MR_METER_TARGET_POWER. Serves a live web dashboard on :8484
  # (the old Express app's /stats port; /stats is kept for compatibility, plus
  # /api/status, /api/history, /api/events SSE).
  #
  #   sudo systemctl restart meter-relay     # picks up a config change
  #   journalctl -u meter-relay -f
  #
  # There is no WorkingDirectory: the configuration arrives in the environment
  # (below), not from a file in the checkout, so the unit no longer depends on
  # the source tree being present.
  systemd.services.meter-relay = {
    serviceConfig = {
      Type = "simple";
      ExecStart = lib.getExe meterRelay;

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
}
