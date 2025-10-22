{ config, lib, pkgs, modulesPath, ... }:

{
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /samsung-4tb/ds-cache 192.168.0.0/16(rw,nohide,insecure,no_subtree_check) 10.47.0.0/16(rw,nohide,insecure,no_subtree_check)
    /samsung-4tb/ds-games 192.168.0.0/16(rw,nohide,insecure,no_subtree_check) 10.47.0.0/16(rw,nohide,insecure,no_subtree_check)
    /samsung-4tb/ds-media 192.168.0.0/16(rw,nohide,insecure,no_subtree_check) 10.47.0.0/16(rw,nohide,insecure,no_subtree_check)
  '';
}
