{
  lib,
  pkgs,
  specialArgs,
}:

let
  nfsServer = "192.168.49.50";
  # nfsPath = "pxe-server-squashfs";
  # nfsPath = "pxe-server-nix-store";
in
lib.nixosSystem {
  inherit pkgs;
  system = "x86_64-linux";
  modules = [
    ./configuration-desktop.nix
    ((import ./netboot.nix) { inherit nfsServer; })
    specialArgs.inputs.stylix.nixosModules.stylix
  ];
}
