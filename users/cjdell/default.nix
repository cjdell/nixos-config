{ config, pkgs, ... }:

{
  imports = [ ./nix.nix ];
  home-manager.users.cjdell = import ./home.nix;
}
