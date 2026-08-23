{ config, lib, ... }:

# diamcp container (rootful podman): mounts the whole home dir into the
# container as a workspace.
#
# nginx: owns the /mcp location on the IP vhost plus the public
# mcp.ai.chrisdell.info subdomain.

let
  # Container tool calls can run long; don't let nginx time out.
  mcpLocation = {
    proxyPass = "http://127.0.0.1:8082/mcp";
    recommendedProxySettings = true;
    proxyWebsockets = true;
    extraConfig = ''
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      proxy_buffering off;
    '';
  };
in
{
  virtualisation.oci-containers.containers.diamcp = {
    hostname = "diamcp";
    image = "localhost/diamcp";
    autoStart = true;
    ports = [ "8082:8000" ];
    volumes = [
      "/home/cjdell:/workspace"
    ];
    extraOptions = [
      "--user=${toString config.users.users.cjdell.uid}:100"
    ];
  };

  services.nginx.virtualHosts = {
    # ---- IP vhost (192.168.49.50) ----

    "192.168.49.50".locations."/mcp" = mcpLocation;

    # ---- Public subdomain ----

    "mcp.ai.chrisdell.info" = {
      useACMEHost = "ai.chrisdell.info";
      forceSSL = true;
      locations = {
        "/" = {
          return = "301 /mcp";
        };
        "= /mcp" = mcpLocation;
      };
    };
  };
}
