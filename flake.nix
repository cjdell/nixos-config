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
  };

  outputs = { self, nixpkgs, nixos-hardware, home-manager }@attrs: {
    nixosConfigurations = {
      zen3-nixos =
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
            ./common/nosleep.nix
            ./common/sunshine.nix
            ./common/system.nix
            ./common/wine.nix
            ./machines/zen3
            ./users/cjdell/permissions.nix
            ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.cjdell = import ./users/cjdell/home.nix;
            }
          ];
        };

      precision-nixos =
        let
          system = "x86_64-linux";
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; }; };
          modules = [
            ./common/desktop.nix
            ./common/nfs.nix
            ./common/system.nix
            ./common/wine.nix
            ./users/cjdell/permissions.nix
            ./machines/precision
            ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"
            nixos-hardware.nixosModules.dell-precision-5520
          ];
        };

      haswellatx-nixos =
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
            ./common/nosleep.nix
            ./common/sunshine.nix
            ./common/system.nix
            ./common/wine.nix
            ./machines/haswellatx
            ./users/cjdell/permissions.nix
            ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.cjdell = import ./users/cjdell/home.nix;
            }
          ];
        };

      haswellmatx-nixos =
        let
          system = "x86_64-linux";
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; }; };
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
            ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.cjdell = import ./users/cjdell/home.nix;
            }
          ];
        };

      kabylakeitx-nixos =
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
            ./common/nosleep.nix
            ./common/sunshine.nix
            ./common/system.nix
            ./machines/kabylakeitx
            ./users/cjdell/permissions.nix
            ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.cjdell = import ./users/cjdell/home.nix;
            }
          ];
        };

      coffeelakelenovo-nixos =
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
            ./common/nosleep.nix
            ./common/sunshine.nix
            ./common/system.nix
            ./machines/coffeelakelenovo
            ./users/cjdell/permissions.nix
            ({ config, pkgs, options, ... }: { nix.registry.nixpkgs.flake = nixpkgs; }) # For "nix shell"
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.cjdell = import ./users/cjdell/home.nix;
            }
          ];
        };

      arcadebox-101 =
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
  };
}
