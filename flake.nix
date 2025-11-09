# sudo nixos-rebuild boot   --impure --flake . --max-jobs 1
# sudo nixos-rebuild switch --impure --flake . --max-jobs 1
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware = {
      # url = "git+file:///home/cjdell/Projects/nixos-hardware";
      url = "github:cjdell/nixos-hardware/master";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    pxe-server = {
      url = "git+file:///home/cjdell/Projects/pxe-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      home-manager,
      plasma-manager,
      pxe-server,
    }@attrs:

    let
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
              permittedInsecurePackages = [
                "broadcom-sta-6.30.223.271-59-6.17.7"
              ];
            };
          };
          home-manager-prefs = {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ];
          };
        in
        {
          zen3-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ((import ./common/folding-at-home.nix) "amd")
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

          zen1-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ((import ./common/folding-at-home.nix) "amd")
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
              (import ./machines/precision pxe-server)
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              nixos-hardware.nixosModules.dell-precision-5520
            ];
          };

          haswellatx-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ((import ./common/folding-at-home.nix) "none")
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

          dell-optiplex-core-4770-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ((import ./common/folding-at-home.nix) "nvidia")
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/podman.nix
              ./common/sunshine.nix
              ./common/sunshine-nvidia.nix
              ./common/system.nix
              ./machines/dell-optiplex-core-4770
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
              ((import ./common/folding-at-home.nix) "none")
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
              ((import ./common/folding-at-home.nix) "nvidia")
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/sunshine-nvidia.nix
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
              ((import ./common/folding-at-home.nix) "nvidia")
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/sunshine-nvidia.nix
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
              ((import ./common/folding-at-home.nix) "nvidia")
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/sunshine-nvidia.nix
              ./common/system.nix
              ./machines/dell-vostro-kabylake
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          lenovo-thinkcentre-core-8400-a-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ((import ./common/folding-at-home.nix) "nvidia")
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/sunshine-nvidia.nix
              ./common/system.nix
              ./machines/lenovo-thinkcentre-core-8400-a
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          lenovo-thinkcentre-core-8400-c-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ((import ./common/folding-at-home.nix) "nvidia")
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/sunshine-nvidia.nix
              ./common/system.nix
              ./machines/lenovo-thinkcentre-core-8400-c
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          hp-elitedesk-ryzen-2400-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/amdgpu.nix
              ./common/desktop.nix
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/hp-elitedesk-ryzen-2400
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
            ];
          };

          lenovo-thinkcentre-core-11400-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ((import ./common/folding-at-home.nix) "nvidia")
              ./common/nfs.nix
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/system.nix
              ./machines/lenovo-thinkcentre-core-11400
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

          macbook-pro-2009-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ./common/nfs.nix
              ./common/podman.nix
              ./common/system.nix
              ./machines/macbook-pro-2009
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
              { environment.systemPackages = with pkgs; [ deskflow ]; }
            ];
          };

          hp-z240-xeon-1240v6-nixos = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              ./common/desktop.nix
              ((import ./common/folding-at-home.nix) "nvidia")
              ./common/nfs.nix
              ./common/podman.nix
              ./common/sunshine.nix
              ./common/sunshine-nvidia.nix
              ./common/system.nix
              ./machines/hp-z240-xeon-1240v6
              ./users/cjdell
              { nix.registry.nixpkgs.flake = nixpkgs; } # For "nix shell"
              home-manager.nixosModules.home-manager
              home-manager-prefs
              { environment.systemPackages = with pkgs; [ deskflow ]; }
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
              ((import ./common/folding-at-home.nix) "none")
              ./common/nosleep.nix
              ./common/sunshine.nix
              ./common/sunshine-xe.nix
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
                permittedInsecurePackages = [ "freeimage-2021-11-01" ];
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
    in
    {
      nixosConfigurations = nixosConfigurations // {
        # Map old names to new names...
        ryzen5hp-nixos = nixosConfigurations.hp-elitedesk-ryzen-2400-nixos;
        rocketlakelenovo-nixos = nixosConfigurations.lenovo-thinkcentre-core-11400-nixos;
        coffeelakelenovo-nixos = nixosConfigurations.lenovo-thinkcentre-core-8400-c-nixos;
      };
    };
}
