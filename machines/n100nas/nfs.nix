{ config, lib, pkgs, modulesPath, ... }:

{
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /sas-16tb/ds-public  192.168.49.0/24(rw,nohide,insecure,no_subtree_check)
  '';
}
