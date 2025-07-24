# sudo nixos-rebuild boot   --impure --flake . --max-jobs 1
# sudo nixos-rebuild switch --impure --flake . --max-jobs 1
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware = {
      # url = "git+file:///home/cjdell/Projects/nixos-hardware";
      url = "github:cjdell/nixos-hardware/master";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      nixos-hardware,
      home-manager,
      plasma-manager,
    }@attrs:
    {
      nixosConfigurations =
        let
          system = "x86_64-linux";
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              packageOverrides = pkgs: {
                fahclient = pkgs.callPackage ./common/overrides/fahclient.nix { };
              };
            };
          };
          pkgs-unstable = import nixpkgs-unstable {
            inherit system;
            config = {
              allowUnfree = true;
            };
          };
          home-manager-prefs = {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.sharedModules = [ plasma-manager.homeManagerModules.plasma-manager ];
          };
        in
        {
          zen3-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/podman.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./common/wine.nix
              ./machines/zen3
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

        zen1-nixos =
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
              ./machines/zen1
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          precision-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/nfs.nix
              ./common/podman.nix
              ./common/system.nix
              ./common/wine.nix
              ./users/cjdell/nix.nix
              ./machines/precision
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              nixos-hardware.nixosModules.dell-precision-5520
            ];
          };

          haswellatx-nixos = nixpkgs.lib.nixosSystem {
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
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          haswelldell-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/podman.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/haswelldell
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          haswellmatx-nixos = nixpkgs.lib.nixosSystem {
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
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          kabylakeitx-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/kabylakeitx
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          # Dell Vostro SFF (i3-8100)
          coffeelakedell-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/coffeelakedell
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          # Dell Vostro SFF (i5-7400)
          dell-vostro-kabylake-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/dell-vostro-kabylake
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };          

          coffeelakelenovo-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/coffeelakelenovo
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          ryzen5hp-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/ryzen5hp
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          rocketlakelenovo-nixos = nixpkgs.lib.nixosSystem {              # { environment.systemPackages = with pkgs-unstable; [ deskflow ]; }

            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/rocketlakelenovo
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          rocketlakelatitude-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/podman.nix
              ./common/system.nix
              ./machines/rocketlakelatitude
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          GEN8-NAS = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/nosleep.nix
              ./common/system.nix
              ./machines/GEN8-NAS
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          N100-NAS = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              # ./common/folding-at-home.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/N100-NAS
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          arcadebox-101 = nixpkgs.lib.nixosSystem {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              config = {
                allowUnfree = true;
                permittedInsecurePackages = [ "freeimage-unstable-2021-11-01" ];
              };
            };
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
