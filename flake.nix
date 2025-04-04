# sudo nixos-rebuild boot   --impure --flake . --max-jobs 1
# sudo nixos-rebuild switch --impure --flake . --max-jobs 1
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    nixos-hardware = {
      # url = "git+file:///home/cjdell/Projects/nixos-hardware";
      url = "github:cjdell/nixos-hardware/master";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = { self, nixpkgs, nixos-hardware, home-manager, plasma-manager }@attrs: {
    nixosConfigurations =
      let
        system = "x86_64-linux";
        pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; }; };
        home-manager-prefs = {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.cjdell = import ./users/cjdell/home.nix;
          home-manager.sharedModules = [ plasma-manager.homeManagerModules.plasma-manager ];
        };
      in
      {
        zen3-nixos =
          nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./common/wine.nix
              ./machines/zen3
              ./users/cjdell/permissions.nix
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

        precision-nixos =
          nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/nfs.nix
              ./common/system.nix
              ./common/wine.nix
              ./users/cjdell/permissions.nix
              ./machines/precision
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              nixos-hardware.nixosModules.dell-precision-5520
            ];
          };

        haswellatx-nixos =
          nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./common/wine.nix
              ./machines/haswellatx
              ./users/cjdell/permissions.nix
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

        haswellmatx-nixos =
          nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              # ./common/boinc.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./common/wine.nix
              ./machines/haswellmatx
              ./users/cjdell/permissions.nix
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

        kabylakeitx-nixos =
          nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/kabylakeitx
              ./users/cjdell/permissions.nix
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

        coffeelakelenovo-nixos =
          nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/coffeelakelenovo
              ./users/cjdell/permissions.nix
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

        ryzen5hp-nixos =
          nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/ryzen5hp
              ./users/cjdell/permissions.nix
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

        rocketlakelenovo-nixos =
          nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/rocketlakelenovo
              ./users/cjdell/permissions.nix
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

        n100nas =
          nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              # ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/n100nas
              ./users/cjdell/permissions.nix
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

        arcadebox-101 =
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
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
            ];
          };
      };
  };
}
