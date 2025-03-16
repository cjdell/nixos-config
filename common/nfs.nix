{ config, pkgs, ... }:

{ 
  fileSystems."/ds-public" = 
    { device = "192.168.49.21:/sas-16tb/ds-public";
      fsType = "nfs";
      options = [ "rw" "hard" "intr" "rsize=1048576" "wsize=1048576" "acregmin=3" "acregmax=60" "acdirmin=30" "acdirmax=60" "noatime" "nodiratime" ];
    };
}
