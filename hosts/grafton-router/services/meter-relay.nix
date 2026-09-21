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
  # reads the grid meter over serial, re-serves it to the Solis/Solax
  # inverters on 192.168.49.30:2000/2001 (stats on :2002) and nudges them with
  # PIDs so grid export tracks MR_METER_TARGET_POWER. Now also serves a live
  # web dashboard on :8484 (the old Express app's /stats port; /stats is kept
  # for compatibility, plus /api/status, /api/history, /api/events SSE).
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
