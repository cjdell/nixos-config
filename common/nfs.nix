{ config, pkgs, ... }:

{
  fileSystems."/ds-public" = {
    device = "192.168.49.21:/sas-16tb/ds-public";
    fsType = "nfs4"; # Use NFSv4 for better performance
    options = [
      "rw"
      "hard"
      "intr"
      "rsize=1048576"
      "wsize=1048576"
      "proto=tcp" # Ensure TCP is used for NFS
      "acregmin=3"
      "acregmax=60"
      "acdirmin=30"
      "acdirmax=120" # Increase dir attribute cache time
      "noatime"
      "nodiratime"
      "x-systemd.after=network-online.target"
    ];
  };

  fileSystems."/ds-downloads" = {
    device = "192.168.49.21:/sas-16tb/ds-downloads";
    fsType = "nfs4"; # Use NFSv4 for better performance
    options = [
      "rw"
      "hard"
      "intr"
      "rsize=1048576"
      "wsize=1048576"
      "proto=tcp" # Ensure TCP is used for NFS
      "acregmin=3"
      "acregmax=60"
      "acdirmin=30"
      "acdirmax=120" # Increase dir attribute cache time
      "noatime"
      "nodiratime"
      "x-systemd.after=network-online.target"
    ];
  };
}
