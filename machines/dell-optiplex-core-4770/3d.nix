{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    orca-slicer
  ];

  virtualisation.oci-containers.containers = {
    # --- KLIPPER ---
    klipper = {
      hostname = "klipper";
      image = "mkuf/klipper:latest";
      autoStart = true;
      volumes = [
        "/dev:/dev"
        "/home/cjdell/Projects/prind.delta/config:/opt/printer_data/config"
        "prinddelta_run:/opt/printer_data/run"
        "prinddelta_gcode:/opt/printer_data/gcodes"
        "prinddelta_log:/opt/printer_data/logs"
      ];
      cmd = [
        "-I"
        "printer_data/run/klipper.tty"
        "-a"
        "printer_data/run/klipper.sock"
        "printer_data/config/printer.cfg"
        "-l"
        "printer_data/logs/klippy.log"
      ];
      extraOptions = [
        "--ip=10.88.0.10"
        "--device=/dev/ttyACM0"
        "--device=/dev/serial/by-id/usb-Klipper_lpc1768_0D40001727953EAE6BC5B753C52000F5-if00"
        # Add container process to group `dialout` so it has permission to access serial devices
        "--group-add=${toString config.users.groups.dialout.gid}"
      ];
    };

    # --- MOONRAKER ---
    moonraker = {
      hostname = "moonraker";
      image = "mkuf/moonraker:latest";
      autoStart = true;
      volumes = [
        "/dev/null:/opt/klipper/config/null"
        "/dev/null:/opt/klipper/docs/null"
        "/run/dbus:/run/dbus"
        "/run/systemd:/run/systemd"
        "prinddelta_run:/opt/printer_data/run"
        "prinddelta_gcode:/opt/printer_data/gcodes"
        "prinddelta_log:/opt/printer_data/logs"
        "prinddelta_moonraker-db:/opt/printer_data/database"
        "/home/cjdell/Projects/prind.delta/config:/opt/printer_data/config"
      ];
      extraOptions = [
        "--ip=10.88.0.11"
      ];
    };

    # --- MAINSAIL ---
    mainsail = {
      hostname = "mainsail";
      image = "ghcr.io/mainsail-crew/mainsail:edge";
      autoStart = true;
      extraOptions = [
        "--ip=10.88.0.12"
      ];
    };
  };

  services.nginx.enable = true;

  services.nginx.virtualHosts = {
    "192.168.49.60" = {
      serverAliases = [ "3d-printer-server.grafton.lan" ];

      locations."/" = {
        proxyPass = "http://10.88.0.12:80";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };

      locations."/websocket" = {
        proxyPass = "http://10.88.0.11:7125";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };

      locations."/printer" = {
        proxyPass = "http://10.88.0.11:7125";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };

      locations."/access" = {
        proxyPass = "http://10.88.0.11:7125";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };

      locations."/machine" = {
        proxyPass = "http://10.88.0.11:7125";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };

      locations."/server" = {
        proxyPass = "http://10.88.0.11:7125";
        recommendedProxySettings = true;
        proxyWebsockets = true;

        extraConfig = ''
          client_max_body_size 500m;
        '';
      };
    };
  };
}
