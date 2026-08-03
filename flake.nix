# sudo nixos-rebuild boot   --impure --flake . --max-jobs 1
# sudo nixos-rebuild switch --impure --flake . --max-jobs 1
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixos-hardware = {
      # url = "git+file:///home/cjdell/Projects/nixos-hardware";
      url = "github:cjdell/nixos-hardware/master";
    };
    nixos-utils = {
      url = "github:cjdell/nixos-utils";
      # url = "git+file:///home/cjdell/Projects/nixos-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # pxe-server = {
    #   url = "git+file:///home/cjdell/Projects/pxe-server";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      nixos-utils,
      sops-nix,
      home-manager,
      plasma-manager,
      # pxe-server,
    }@inputs:

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
      homeManagerPrefs = {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ];
      };
      commonModules = {
        imports = [
          nixos-utils.nixosModules.rollback
          nixos-utils.nixosModules.containers
        ];
        # Make `nix-shell` use packages from this flake
        nix.registry.nixpkgs.flake = nixpkgs;
      };
    in
    {
      nixosConfigurations =
        # Find configs in `hosts` folder and use the folder name as the host name
        (
          let
            hosts = builtins.filter (x: x != null) (
              nixpkgs.lib.mapAttrsToList (name: value: if (value == "directory") then name else null) (
                builtins.readDir ./hosts
              )
            );
          in
          builtins.listToAttrs (
            (map (host: {
              name = host;
              value = nixpkgs.lib.nixosSystem {
                inherit system pkgs;
                modules = [
                  # This fixes nixpkgs (for e.g. "nix shell") to match the system nixpkgs
                  { networking.hostName = host; }
                  ./common/system.nix
                  ./users/cjdell
                  home-manager.nixosModules.home-manager
                  homeManagerPrefs
                  commonModules

                ]
                ++ (import (./hosts + "/${host}") inputs);
                specialArgs = {
                  inherit inputs;
                };
              };
            }))
              hosts
          )
        )
        #  Legacy configs for old machines (to be converted)
        // {
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              nixos-hardware.nixosModules.dell-precision-5520
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
            ];
          };

          "3d-printer-server" = nixpkgs.lib.nixosSystem {
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
            ];
          };

          N40L-NAS = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              sops-nix.nixosModules.sops
              ./common/nosleep.nix
              ./common/sops.nix
              ./common/system.nix
              ./machines/N40L-NAS
              ./users/cjdell
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
            ];
          };

          GEN8-NAS = nixpkgs.lib.nixosSystem {
            inherit system pkgs;
            modules = [
              sops-nix.nixosModules.sops
              ./common/nosleep.nix
              ./common/sops.nix
              ./common/system.nix
              ./machines/GEN8-NAS
              ./users/cjdell
              home-manager.nixosModules.home-manager
              homeManagerPrefs
              commonModules
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
            ];
          };
        };
    };
}
