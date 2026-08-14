{
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /sas-24tb/ds-downloads  192.168.0.0/16(rw,nohide,insecure,no_subtree_check) 10.47.0.0/16(rw,nohide,insecure,no_subtree_check)
    /sas-24tb/ds-public     192.168.0.0/16(rw,nohide,insecure,no_subtree_check)
    /sas-24tb/ds-home       192.168.0.0/16(rw,nohide,insecure,no_subtree_check,async,no_auth_nlm,no_root_squash)
  '';
}
