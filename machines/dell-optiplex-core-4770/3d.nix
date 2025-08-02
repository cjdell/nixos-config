{ config, pkgs, ... }:

{
  # services.klipper = {
  #   enable = true;
  # };

  environment.systemPackages = with pkgs; [
    orca-slicer
  ];
}
