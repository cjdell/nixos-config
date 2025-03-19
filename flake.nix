# sudo nixos-rebuild boot --impure --flake . --max-jobs 1
# sudo nixos-rebuild switch --impure --flake . --max-jobs 1
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
          ./common/wine.nix
          ./users/cjdell.nix
          ./machines/precision
          ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"
          nixos-hardware.nixosModules.dell-precision-5520
        ];
      };
    nixosConfigurations.haswellatx-nixos =
      let
        system = "x86_64-linux";
      in
      nixpkgs.lib.nixosSystem {
        inherit system;
        pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; }; };
        modules = [
          ./common/desktop.nix
          ./common/folding-at-home.nix
          ./common/nfs.nix
          ./common/sunshine.nix
          ./common/system.nix
          ./common/wine.nix
          ./users/cjdell.nix
          ./machines/haswellatx
          ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"

        ];
      };
    nixosConfigurations.arcadebox-101 =
      let
        system = "x86_64-linux";
      in
      nixpkgs.lib.nixosSystem {
        inherit system;
        pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; permittedInsecurePackages = [ "freeimage-unstable-2021-11-01" ]; }; };
        modules = [
          ./common/arcade.nix
          ./common/desktop.nix
          ./common/sunshine.nix
          ./common/nosleep.nix
          ./common/system.nix
          ./users/user.nix
          ./machines/arcadebox-101
          ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"

        ];
      };
  };
}
