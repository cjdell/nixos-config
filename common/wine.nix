{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    bottles
    lutris
    wineWow64Packages.waylandFull
  ];

  programs.steam.enable = true;
}
