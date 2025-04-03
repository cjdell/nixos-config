{ config, pkgs, ... }:

{
  services.boinc.enable = true;
  services.boinc.extraEnvPackages = with pkgs; [
    libglvnd
    brotli
    ocl-icd
    virtualbox
  ];

  virtualisation.virtualbox.host = {
    enable = true;
  };

  users.groups.boinc.members = [ "cjdell" ];
  users.groups.vboxusers.members = [ "boinc" ];
}
