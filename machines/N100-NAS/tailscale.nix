{ config, lib, pkgs, modulesPath, ... }:

{
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_pre_auth_key.path;
    extraUpFlags = [
      "--login-server=https://tailscale.home.chrisdell.info"
      "--accept-routes=false"
      "--accept-dns"
    ];
  };
}
