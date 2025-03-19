{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    bottles
    lutris
    wineWowPackages.waylandFull
  ];

  programs.steam.enable = true;
}
