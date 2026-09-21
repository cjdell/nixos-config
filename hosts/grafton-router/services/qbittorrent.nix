# qBittorrent's WebUI runs on N100-NAS (192.168.49.22:8081 — see that host's
# hosts/N100-NAS/qbittorrent.nix in the nixos-config repo). qBittorrent has no
# native OIDC, so this is the "SSO in front, qBittorrent login skipped"
# arrangement: nginx-sso (Kanidm) authenticates the user, and qBittorrent is
# configured on N100-NAS (WebUI\AuthSubnetWhitelist=192.168.49.1/32) to skip
# its own login for requests arriving from this router. Direct access to
# 192.168.49.22:8081 still uses qBittorrent's own username/password.
let
  mkSSOVirtualHost = import ../../../utils/nginx-sso-helper.nix;
in
{
  services.nginx.virtualHosts."qbittorrent.home.chrisdell.info" = mkSSOVirtualHost {
    proxyPass = "http://192.168.49.22:8081";
  };
}
