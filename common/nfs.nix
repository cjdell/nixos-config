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

  fileSystems."/ds-games" = {
    device = "192.168.49.22:/samsung-4tb/ds-games";
    fsType = "nfs4";
    options = [
      "rw"
      "hard"
      "intr"
      "rsize=1048576"
      "wsize=1048576"
      "proto=tcp"
      "acregmin=3"
      "acregmax=60"
      "acdirmin=60" # Increased from 30
      "acdirmax=180" # Increased from 120
      "noatime"
      "nodiratime"
      "nconnect=8" # Added for multiple connections
      "x-systemd.after=network-online.target"
    ];
  };
}
