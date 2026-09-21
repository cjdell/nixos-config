{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  mkSSOVirtualHost = import ../../../utils/nginx-sso-helper.nix;
  # Per-system package set (frigate-monitor's flake packages are nested by system)
  fm = inputs.frigate-monitor.packages.${pkgs.hostPlatform.system}.default;
in
{
  # ============================================================================
  # frigate-monitor — static scene-change detection for Frigate cameras
  # Web UI: https://frigate-monitor.home.chrisdell.info (SSO protected)
  #
  # Periodically snapshots each camera (go2rtc frame API, or raw RTSP via
  # ffmpeg) and maintains dual-time-constant luma background models per
  # camera. The persistent difference between the fast and slow background
  # highlights objects that were placed, removed, or moved — while moving
  # objects (people) average out and are ignored. Each change is stored as
  # a thumbnail that reveals before/after full frames (region outlined) plus
  # zoomed crops of the change. Events are plain files under
  # /var/lib/frigate-monitor (no DB), pruned hourly.
  #
  # The SPA does no auth of its own: nginx-sso (mkSSOVirtualHost) guards the
  # vhost and sets X-WEBAUTH-USER, which /api/user surfaces.
  # ============================================================================

  users.users.frigate-monitor = {
    uid = 8973;
    group = "users";
    isNormalUser = true;
  };

  systemd.services.frigate-monitor = {
    description = "Static scene-change detection for RTSP cameras";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      User = "frigate-monitor";
      Group = "users";
      ExecStart = "${fm}/bin/frigate-monitor";
      Environment = [
        "FM_CONFIG=/etc/frigate-monitor.toml"
        "FM_WEB_DIR=${fm}/share/frigate-monitor"
      ];
      StateDirectory = "frigate-monitor";
      StateDirectoryMode = "0750";
      Restart = "always";
      RestartSec = "5s";
    };
    # rtsp:// sources are captured with ffmpeg (not in the default PATH)
    path = [ pkgs.ffmpeg-headless ];
  };

  environment.etc."frigate-monitor.toml".text = ''
    listen = "127.0.0.1:8093"
    state_dir = "/var/lib/frigate-monitor"
    interval_secs = 15
    keep_events = 500
    retention_days = 30

    [cameras.front_door]
    # go2rtc frame API — same stream as rtsp://127.0.0.1:8554/front_door,
    # delivered as a JPEG over HTTP (more robust than repeated RTSP grabs).
    # Raw RTSP also works: source = "rtsp://127.0.0.1:8554/front_door"
    source = "http://127.0.0.1:1984/api/frame.jpeg?src=front_door"
  '';

  # --- nginx / SSO ------------------------------------------------------------
  services.nginx.virtualHosts."frigate-monitor.home.chrisdell.info" = mkSSOVirtualHost {
    proxyPass = "http://127.0.0.1:8093";
  };
}
