{ config, lib, pkgs, modulesPath, ... }:

{
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /samsung-4tb/ds-fast 192.168.0.0/16(rw,nohide,insecure,no_subtree_check)
  '';
}
