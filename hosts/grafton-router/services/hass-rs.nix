# hass-rs — the shadow Home Assistant hub (crates/home-assistant-rust).
#
# Runs beside the real linuxserver/homeassistant container, consumes the same
# Mosquitto/zigbee2mqtt tree, imports HA's registries and last-known states
# read-only, and serves a server-rendered Topcoat dashboard. It does NOT run
# automations (that would fire the estate's automations a second time) and its
# HA-compatible API is loopback-only on :8126 (8124 is zigbee2mqtt's web UI);
# nginx fronts the dashboard on :8125 at hass-rs.home.chrisdell.info.
#
# The crate is a git submodule consumed as the `home-assistant-rust` flake
# path input. If this host is rebuilt after editing the submodule, refresh the
# lock first:  nix flake update home-assistant-rust
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  net = import ../networking/constants.nix;

  hass-rs = pkgs.callPackage "${inputs.home-assistant-rust}/nix/package.nix" {
    craneLib = inputs.crane.mkLib pkgs;
  };

  # hass-rs reads configuration.yaml, then the .storage registries and
  # core.restore_state from the same directory. Only .storage is shared with
  # the live HA install; the MQTT block lives here because the real HA keeps
  # its MQTT broker in a config entry rather than YAML.
  configDir = pkgs.linkFarm "hass-rs-config" [
    {
      name = "configuration.yaml";
      path = pkgs.writeText "hass-rs-configuration.yaml" ''
        default_config:

        latitude: 51.4964
        longitude: -0.1224
        time_zone: Europe/London
        location_name: Home

        # Mosquitto is the router's own listener (see mosquitto.nix); the
        # client id must not collide with the real HA or zigbee2mqtt.
        mqtt:
          broker: ${net.LAN_IPV4}
          port: 1883
          client_id: hass-rs-shadow

        http:
          # The HA-compatible API has no token in shadow mode: keep it on
          # loopback. Only nginx (dashboard :8125) is exposed.
          server_host: 127.0.0.1
          server_port: 8126
      '';
    }
    # Read-only view of HA's registries: areas, entity/device ids, restore
    # state. The linkFarm symlink is resolved by the service user, which is
    # in the `users` group so it can read the 0664 registry files.
    {
      name = ".storage";
      path = "/srv/homeassistant/config/.storage";
    }
  ];
in
{
  users.users.hass-rs = {
    isSystemUser = true;
    group = "users";
    description = "hass-rs shadow Home Assistant hub";
  };

  systemd.services.hass-rs = {
    description = "hass-rs shadow Home Assistant hub";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "mosquitto.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        "${hass-rs}/bin/hass-rs"
        "--config"
        configDir
        "--port"
        "8126"
        "--web-host"
        "127.0.0.1"
        "--web-port"
        "8125"
        "--no-automations"
      ];
      User = "hass-rs";
      Group = "users";
      Restart = "on-failure";
      RestartSec = 5;
      LimitCORE = 0;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
    environment.RUST_LOG = "info,hass_rs=info,hass_mqtt=info,hass_web=info";
  };

  services.nginx.virtualHosts."hass-rs.home.chrisdell.info" = {
    useACMEHost = "chrisdell.info";
    forceSSL = true;

    locations."/" = {
      proxyPass = "http://127.0.0.1:8125";
      recommendedProxySettings = true;
      proxyWebsockets = true;

      extraConfig = ''
        # The dashboard has no login: it is a control surface for Zigbee
        # devices, so restrict it to the LAN and our two VPNs. Anything else
        # (including the public internet) gets 403. The *_SUBNET values come
        # from networking/constants.nix.
        allow ${net.LAN_SUBNET};
        allow ${net.VLAN10_SUBNET};
        allow ${net.WIREGUARD_SUBNET};
        allow ${net.TAILSCALE_SUBNET};
        allow ${net.LAN_IPV6_PREFIX}/64;
        deny all;

        # The Topcoat runtime keeps a WebSocket open per dashboard tab for
        # live-region updates (proxyWebsockets above carries the upgrade);
        # long timeouts so idle connections are not cut, no buffering.
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 24h;
      '';
    };
  };
}
