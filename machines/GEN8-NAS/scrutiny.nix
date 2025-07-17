{ config, lib, pkgs, modulesPath, ... }:

{
  services.scrutiny = {
    enable = true;
  };
}
