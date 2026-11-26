{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [
      ./adguard.nix
      ./bittorrent.nix
      ./filebrowser.nix
      ./frigate.nix
      ./homeassistant.nix
      ./immich.nix
      ./jellyfin.nix
      ./librespeed.nix
      ./mosquitto.nix
      ./postgres.nix
      ./samba.nix
      ./unifi.nix
      ./whoogle.nix
    ];
}
