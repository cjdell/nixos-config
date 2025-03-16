# sudo nixos-rebuild boot --flake . --max-jobs 1
# sudo nixos-rebuild switch --flake . --max-jobs 1
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    nixos-hardware.url = "github:cjdell/nixos-hardware/master";
    # nixos-hardware.url = "git+file:///home/cjdell/Projects/nixos-hardware";
  };

  outputs = { self, nixpkgs, nixos-hardware }@attrs: {
    nixosConfigurations.precision-nixos =
      let
        system = "x86_64-linux";
        # nixos-hardware = (builtins.getFlake "/home/cjdell/Projects/nixos-hardware");
      in
      nixpkgs.lib.nixosSystem {
        inherit system;
        pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; }; };
        modules = [
          ./common/desktop.nix
          ./common/nfs.nix
          ./common/system.nix
          ./users/cjdell.nix
          ./machines/precision
          ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"
          nixos-hardware.nixosModules.dell-precision-5520
        ];
      };
  };
}
