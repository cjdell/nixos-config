{ config, lib, pkgs, modulesPath, ... }:

{
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /sas-16tb/ds-downloads  192.168.0.0/16(rw,nohide,insecure,no_subtree_check) 10.47.0.0/16(rw,nohide,insecure,no_subtree_check)
    /sas-16tb/ds-public     192.168.0.0/16(rw,nohide,insecure,no_subtree_check)
  '';
}
