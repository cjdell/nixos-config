# alderlake-thinkpad offloads all Nix builds to the zen3-nixos build machine
# (192.168.49.50): nix.settings.max-jobs = 0 disables local builds and the
# daemon schedules up to 16 parallel jobs on the remote. Do NOT pass --max-jobs
# to nixos-rebuild there — it overrides that and serializes remote builds.
# Hosts without a build machine can still append --max-jobs 1 to keep builds
# light on limited-RAM targets.
# sudo nixos-rebuild boot   --impure --flake .
# sudo nixos-rebuild switch --impure --flake .
{
  inputs = {
    # Stable nixpkgs: every host except alderlake-thinkpad (see nixpkgsFor).
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Unstable nixpkgs: hosts opt in per-host (see nixpkgsFor in outputs).
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
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
    # master for hosts on unstable nixpkgs (see homeManagerFor)
    home-manager-unstable = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    stylix = {
      url = "github:nix-community/stylix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llama-cpp = {
      url = "github:ggml-org/llama.cpp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # stew675's RDNA performance fork (HIP/CUDA backend only): RDNA4 WMMA
    # flash-attn, gfx1201 mmvq decode, fused MoE/SSM kernels, adaptive MTP.
    # Used for the R9700 router in hosts/zen3-nixos/ai.nix (vega/rx580 stay
    # on the upstream Vulkan build).
    llama-cpp-rdna = {
      url = "github:stew675/llama.cpp/rdna-boosts";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llama-cpp-uma = {
      url = "git+file:///home/cjdell/Projects/llama.cpp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko-zfs = {
      url = "github:numtide/disko-zfs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
    # Bleeding-edge Zed: source build tracking zed main (via zed.overlays.default),
    # replaces nixpkgs' zed-editor package which ships the prebuilt release channel.
    zed.url = "github:zed-industries/zed";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      nixos-hardware,
      nixos-utils,
      sops-nix,
      home-manager,
      home-manager-unstable,
      plasma-manager,
      stylix,
      llama-cpp,
      llama-cpp-rdna,
      llama-cpp-uma,
      disko,
      disko-zfs,
      zed,
    }@inputs:

    let
      system = "x86_64-linux";

      # zed-editor from the zed flake's own package output rather than its
      # overlay: the overlay builds against each host's nixpkgs, which fails on
      # stable nixos-26.05 (nixpkgs' cargo-about passes --features=cli, which
      # the 0.8.2 that zed pins lacks). The flake package builds against zed's
      # own pinned nixpkgs and is a single derivation shared by every host.
      zed-editor-overlay = _final: _prev: {
        zed-editor = zed.packages.${system}.default;
      };

      # ddcci-driver (out-of-tree DDC/CI module) fails to compile against Linux
      # 7.2: the kernel removed the strncpy declaration from <linux/string.h>
      # (only strscpy remains), so ddcci.c's five strncpy() calls fail as
      # implicit-declaration errors under GCC 15. Migrate them to strscpy()
      # (identical output for these sysfs show() functions, return value
      # unused) and add the explicit <linux/string.h> include. Applies to every
      # linuxPackages* attrset (hosts use both the default and
      # linuxPackages_latest). Done via the postPatch hook (not patchPhase) so
      # nixpkgs' prePatch Makefile substitute still runs; inline sed instead of
      # a patch file keeps the flake source free of new files (flake paths must
      # be tracked by git, and the tree is often dirty).
      ddcci-driver-overlay =
        final: prev:
        let
          patchDdcci =
            pkg:
            pkg.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                sed -i 's/strncpy(/strscpy(/g' ddcci/ddcci.c
                sed -i '\|#include <linux/slab.h>|a #include <linux/string.h>' ddcci/ddcci.c
              '';
            });
          patchSet = set: set // { ddcci-driver = patchDdcci set.ddcci-driver; };
        in
        builtins.mapAttrs (
          name: value:
          if builtins.isAttrs value && value ? ddcci-driver then
            # linuxPackages attrsets are extensible; `//` would orphan our
            # override from future extends, so prefer extend when available.
            if value ? extend then
              value.extend (_: super: { ddcci-driver = patchDdcci super.ddcci-driver; })
            else
              patchSet value
          else
            value
        ) prev;

      # Build a pkgs set from a given nixpkgs input (shared package config).
      mkPkgs =
        nixpkgs:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            packageOverrides = pkgs: {
              fahclient = pkgs.callPackage ./common/overrides/fahclient.nix { };
              # moonlight-qt 6.1.0 doesn't build against ffmpeg 9 (unstable's
              # default); nixpkgs master pins it to ffmpeg_8, mirror that here.
              moonlight-qt = pkgs.moonlight-qt.override { ffmpeg = pkgs.ffmpeg_8; };
            };
            permittedInsecurePackages = [
              "broadcom-sta-6.30.223.271-59-6.17.7"
            ];
          };
          # Bleeding-edge zed-editor (source build tracking main) instead of the
          # prebuilt release binary that nixpkgs' zed-editor packages.
          overlays = [
            zed-editor-overlay
            ddcci-driver-overlay
          ];
        };

      # Stable pkgs used by the legacy machines below.
      pkgs = mkPkgs nixpkgs;

      # Which nixpkgs each host runs on: hosts listed here opt into unstable,
      # everything else uses the stable `nixpkgs` input.
      nixpkgsFor = host: if host == "alderlake-thinkpad" then nixpkgs-unstable else nixpkgs;

      # Home-manager follows the same split: the release branch for stable
      # hosts, master for hosts on unstable nixpkgs.
      homeManagerFor = host: if host == "alderlake-thinkpad" then home-manager-unstable else home-manager;

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

      # Build one host with the nixpkgs input that nixpkgsFor picks for it.
      mkHost =
        host:
        let
          hostPkgs = nixpkgsFor host;
          hostHomeManager = homeManagerFor host;
        in
        hostPkgs.lib.nixosSystem {
          inherit system;
          pkgs = mkPkgs hostPkgs;
          modules = [
            # This fixes nixpkgs (for e.g. "nix shell") to match the system nixpkgs
            { networking.hostName = host; }
            # Point the registry at the host's nixpkgs (unstable on opted-in hosts)
            ({ lib, ... }: {
              nix.registry.nixpkgs.flake = lib.mkForce hostPkgs;
            })
            ./common/system.nix
            ./users/cjdell
            hostHomeManager.nixosModules.home-manager
            homeManagerPrefs
            commonModules
          ]
          ++ (import (./hosts + "/${host}") inputs);
          specialArgs = {
            inherit inputs;
          };
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
            map (host: {
              name = host;
              value = mkHost host;
            }) hosts
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

          # N40L-NAS = nixpkgs.lib.nixosSystem {
          #   inherit system pkgs;
          #   modules = [
          #     sops-nix.nixosModules.sops
          #     ./common/nosleep.nix
          #     ./common/sops.nix
          #     ./common/system.nix
          #     ./machines/N40L-NAS
          #     ./users/cjdell
          #     home-manager.nixosModules.home-manager
          #     homeManagerPrefs
          #     commonModules
          #   ];
          # };

          arcadebox-101 = nixpkgs.lib.nixosSystem {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              config = {
                allowUnfree = true;
                permittedInsecurePackages = [ "freeimage-2021-11-01" ];
              };
              # Same zed-editor overlay as mkPkgs (arcadebox installs desktop.nix).
              overlays = [ zed-editor-overlay ];
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
