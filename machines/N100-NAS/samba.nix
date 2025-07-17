{ config, lib, pkgs, modulesPath, ... }:

{
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "N100-NAS";
        "netbios name" = "N100-NAS";
        "security" = "user";
        #"use sendfile" = "yes";
        "min protocol" = "SMB2";
        # note: localhost is the ipv6 localhost ::1
        "hosts allow" = "192.168. 10.47. 127.0.0.1 localhost";
        "hosts deny" = "0.0.0.0/0";
        "guest account" = "nobody";
        "map to guest" = "bad user";

        "protocol" = "SMB3";
        "vfs objects" = "acl_xattr fruit catia streams_xattr aio_pthread";

        "fruit:aapl" = "yes";
        "fruit:model" = "MacSamba";
        "fruit:posix_rename" = "yes";
        "fruit:metadata" = "stream";
        "fruit:nfs_aces" = "no";
        "fruit:veto_appledouble" = "no";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:delete_empty_adfiles" = "yes";

        "recycle:keeptree" = "no";
        "oplocks" = "yes";
        "locking" = "yes";
      };
      "Fast" = {
        "path" = "/samsung-4tb/ds-fast";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "cjdell";
        "force group" = "users";
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };
}
