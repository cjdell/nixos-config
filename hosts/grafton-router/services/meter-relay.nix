{
  lib,
  pkgs,
  inputs,
  ...
}:

let
  # Built from /home/cjdell/Projects/meter-relay-rs via its own flake (see the
  # meter-relay-rs input in flake.nix): a self-contained Rust binary — serial
  # grid meter, Modbus TCP to the inverters, PID load balancing, HA/Influx
  # publishing — with the Solid.js dashboard bundled in and served from the
  # store (the wrapper sets MR_WEB_DIR).
  meterRelay = inputs.meter-relay-rs.packages.${pkgs.hostPlatform.system}.default;
in
{
  # Rust port of the former TypeScript meter-relay. Same job, same ports:
  # reads the grid meter over serial, re-serves it to the inverters on
  # 192.168.49.30:2000/2001 (stats on :2002) and nudges them with PIDs so grid
  # export tracks MR_METER_TARGET_POWER. Now also serves a live web dashboard on
  # :8484 (the old Express app's /stats port; /stats is kept for compatibility,
  # plus /api/status, /api/history, /api/events SSE).
  #
  # The plant is a priority list, not two hardcoded inverters: MR_INVERTERS
  # orders it and MR_<ID>_* configures each entry, so a third inverter is a
  # .env change (plus a driver, if it is a new make/model). The first entry is
  # the primary actuator; the rest are the reserve, which covers demand the
  # primary cannot and also absorbs the PV surplus the primary's charge taper
  # cannot take.
  #
  # WorkingDirectory points at the checkout so the binary reads the MR_
  # credentials from its .env there (gitignored; the TS copy is in
  # /home/cjdell/Projects/meter-relay/.env).
  #
  # sudo systemctl restart meter-relay
  # journalctl -u meter-relay -f
  systemd.services.meter-relay = {
    serviceConfig = {
      Type = "simple";
      WorkingDirectory = "/home/cjdell/Projects/meter-relay-rs";
      ExecStart = "${lib.getExe meterRelay}";
      Restart = "always";
      RestartSec = 5;
    };
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
  };
}
