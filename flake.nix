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
    # The Raspberry Pi 5 netboot flake (Pi NixOS config + the gc-node worker it
    # runs). hosts/zen3-nixos/pi5-netboot.nix bind-mounts its pi5-netboot
    # package at /etc/tftp/e9cf02dc. A `path:` input freezes at the locked
    # narHash — after editing that repo, refresh with:
    #   nix flake lock --update-input gc-rust-node
    # NB: does NOT follow this flake's nixpkgs — the Pi keeps its own tested
    # pin (gc-rust-node/flake.lock), and zen3 just references the built drv.
    gc-rust-node = {
      url = "path:/home/cjdell/Projects/gc-business/gc-rust-node";
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
    # llama.cpp for Qwen3.8-Flash-Next MTP, as a LOCAL repo (see
    # /home/cjdell/Projects/llama-mtp): upstream ggml-org master (rev
    # 42f0225, 2026-09-03) + the two open upstream qwen4exp-MTP PRs merged on
    # top — ggml-org#27836 "qwen4exp: add NextN/MTP draft head" and #28097
    # "support draft-head-only GGUFs (unsloth layout)" — plus a backport of
    # unslothai/llama.cpp#144's cross-model tensor borrowing so the unsloth
    # `shared` MTP head files work. WHY NOT THE FORK: unsloth's release tag
    # b10715-mix-86bd2d3 tracks their master, which has NO qwen4exp arch at
    # all ("unknown model architecture" from source); their PR branch
    # mtp/qwen4exp-nextn works but sits on an Aug-31 base that predates the
    # merged upstream decode fixes (e.g. #28123 recurrent-state rollback:
    # "MTP slower than no draft" -> +50-90% decode on the LocalLLaMA thread;
    # #28023 indexer prefill). The local repo = the fork's MTP code, but on
    # today's master with those fixes + borrowing. Refresh after editing the
    # repo with: nix flake lock --update-input llama-cpp-mtp
    llama-cpp-mtp = {
      url = "git+file:///home/cjdell/Projects/llama-mtp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # stew675's RDNA performance fork (HIP/CUDA backend only): RDNA4 WMMA
    # flash-attn, gfx1201 mmvq decode, fused MoE/SSM kernels, adaptive MTP.
    # Previously used for the R9700 router (hosts/zen3-nixos/ai/llama-swap.nix);
    # the router moved to the upstream Vulkan build (2026-08-23) because MTP
    # draft acceptance was 0 on the HIP fork. Kept as an input for reference /
    # easy re-enable; nothing references it while unbuilt (lazy).
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
      gc-rust-node,
      sops-nix,
      home-manager,
      home-manager-unstable,
      plasma-manager,
      stylix,
      llama-cpp,
      llama-cpp-mtp,
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
        # zed-editor = zed.packages.${system}.default;
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

      # broadcom-sta (out-of-tree Broadcom STA wireless module) fails to
      # compile against Linux 7.2: strncpy() calls in osl_strncpy() (and
      # osl_debug_malloc(), under BCMDBG_MEM) plus two more in wl_linux.c hit
      # GCC 15's implicit-function-declaration error, because modern kernels
      # dropped strncpy from <linux/string.h> — and the kernel no longer
      # exports the strncpy symbol either, so merely including <string.h>
      # would compile but fail at modpost. Migrate the calls to strscpy()
      # (sized_strscpy is exported; the original code NUL-terminates the
      # destination itself, so the output is identical). The third
      # strncpy() in wl_linux.c sits under #if __GNUC__ < 8 and is dead
      # code, so it is left alone. Same linuxPackages attrset handling as
      # ddcci-driver above; the sed patterns are no-ops (exit 0) on
      # attrsets whose broadcom_sta predates these lines.
      # On kernel >= 6.13 the cfg80211 key/station ops also changed shape:
      # get_station/add_key/del_key/get_key take struct wireless_dev *wdev
      # instead of struct net_device * (GCC 15 errors on the incompatible
      # pointer init). A perl script (delivered via writeText so the fix
      # stays inline — no new flake files; a bash heredoc would not work
      # because nixfmt re-indents `''` string content, which would break
      # the column-0 heredoc terminator) migrates the active #if-branch
      # prototypes/definitions and adds a `dev = wdev->netdev` local at the
      # top of each body; it dies loudly if any anchor stops matching.
      broadcom-sta-overlay =
        final: prev:
        let
          hybridFix = final.writeText "broadcom-sta-hybrid-fix.pl" ''
            #!/usr/bin/env perl
            # cfg80211 wdev migration for broadcom-sta (kernel >= 6.13):
            # get_station/add_key/del_key/get_key ops now take struct wireless_dev *wdev
            # instead of struct net_device *. Update the active #if branch signatures
            # (prototypes + definitions) and add a local `dev` alias at the top of each
            # body so the untouched bodies keep working.
            use strict;
            use warnings;

            my $file = $ARGV[0] or die "usage: $0 <file>\n";
            open my $fh, '<', $file or die "cannot read $file: $!\n";
            my $src = do { local $/; <$fh> };
            close $fh;

            my $local = "\tstruct net_device *dev = wdev->netdev;\n";
            my @subs = (
              # add_key, active (>= 6.1.0) branch: prototype + definition
              [qr/struct net_device \*dev,(\n\s*int link_id, u8 key_idx, bool pairwise, const u8 \*mac_addr, struct key_params \*params\))/,
               sub { 'struct wireless_dev *wdev,' . $1 }],
              # del_key, active branch: prototype + definition
              [qr/struct net_device \*dev,(\n\s*int link_id, u8 key_idx, bool pairwise, const u8 \*mac_addr\))/,
               sub { 'struct wireless_dev *wdev,' . $1 }],
              # get_key, active branch definition: `void *cookie,` on the 2nd line
              [qr/struct net_device \*dev,(\n\s*int link_id, u8 key_idx, bool pairwise, const u8 \*mac_addr, void \*cookie,)/,
               sub { 'struct wireless_dev *wdev,' . $1 }],
              # get_key, active branch prototype: `void *cookie,` on its own 3rd line
              [qr/(wl_cfg80211_get_key\(struct wiphy \*wiphy, )struct net_device \*dev,(\n\s*int link_id, u8 key_idx, bool pairwise, const u8 \*mac_addr,\n\s*void \*cookie,)/,
               sub { $1 . 'struct wireless_dev *wdev,' . $2 }],
              # get_station, active (>= 3.16.0) definition: `const u8 *mac`
              [qr/struct net_device \*dev,(\n\s*const u8 \*mac, struct station_info \*sinfo\))/,
               sub { 'struct wireless_dev *wdev,' . $1 }],
              # get_station, active prototype (single-line params, `const u8 *mac`)
              [qr/struct net_device \*dev, const u8 \*mac, struct station_info \*sinfo\);/,
               sub { 'struct wireless_dev *wdev, const u8 *mac, struct station_info *sinfo);' }],
              # body-local insertions, anchored on unique text
              [qr/(u8 key_idx, const u8 \*mac_addr, struct key_params \*params\)\n#endif\n)\{\n/,
               sub { $1 . "{\n$local" }],
              [qr/\{\n(\tstruct wl_wsec_key key;)/,
               sub { "{\n$local" . $1 }],
              [qr/\{\n(\tstruct key_params params;)/,
               sub { "{\n$local" . $1 }],
              [qr/(const u8 \*mac, struct station_info \*sinfo\)\n#endif\n)\{\n/,
               sub { $1 . "{\n$local" }],
            );

            for my $s (@subs) {
              my ($re, $fn) = @$s;
              my $count = ($src =~ s/$re/$fn->()/ge);
              die "no match for: $re\n" unless $count;
              print "applied ($count)\n";
            }

            open my $out, '>', $file or die "cannot write $file: $!\n";
            print $out $src;
            close $out;
            print "wrote $file\n";
          '';
          patchBroadcomSta =
            pkg:
            pkg.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                sed -i 's/return (strncpy(d, s, n));/strscpy(d, s, n); return (d);/' src/shared/linux_osl.c
                sed -i 's/strncpy(p->file, basename, BCM_MEM_FILENAME_LEN);/strscpy(p->file, basename, BCM_MEM_FILENAME_LEN);/' src/shared/linux_osl.c
                sed -i 's/strncpy(dev->name, intf_name, IFNAMSIZ-1);/strscpy(dev->name, intf_name, IFNAMSIZ);/' src/wl/sys/wl_linux.c
                sed -i 's/strncpy(info->version, EPI_VERSION_STR, sizeof(info->version));/strscpy(info->version, EPI_VERSION_STR, sizeof(info->version));/' src/wl/sys/wl_linux.c
                perl ${hybridFix} src/wl/sys/wl_cfg80211_hybrid.c
              '';
            });
        in
        builtins.mapAttrs (
          name: value:
          if builtins.isAttrs value && value ? broadcom_sta then
            if value ? extend then
              value.extend (_: super: { broadcom_sta = patchBroadcomSta super.broadcom_sta; })
            else
              value // { broadcom_sta = patchBroadcomSta value.broadcom_sta; }
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
              "broadcom-sta-6.30.223.271-59-7.2.3"
            ];
          };
          # Bleeding-edge zed-editor (source build tracking main) instead of the
          # prebuilt release binary that nixpkgs' zed-editor packages.
          overlays = [
            zed-editor-overlay
            ddcci-driver-overlay
            broadcom-sta-overlay
          ];
        };

      # Stable pkgs used by the legacy machines below.
      pkgs = mkPkgs nixpkgs;

      # Upstream llama.cpp's flake packages build the FULL test suite by
      # default: .devops/nix/package.nix never sets LLAMA_BUILD_TESTS, so cmake's
      # default (ON) compiles ~850 test targets — and parallel test compilation
      # ICEs GCC on test-jinja.cpp (GGC crash; same failure documented for the
      # rdna-boosts fork in AGENTS.md). The tests are useless for a server
      # deployment anyway, so wrap every package with -DLLAMA_BUILD_TESTS=OFF.
      llamaCppPkgs = builtins.mapAttrs (
        _: pkg:
        pkg.overrideAttrs (old: {
          cmakeFlags = old.cmakeFlags ++ [ "-DLLAMA_BUILD_TESTS=OFF" ];
        })
      ) llama-cpp.packages.${system};

      # Same test-off wrapper for the local llama-cpp-mtp repo (see llamaCppPkgs).
      # Exposed via specialArgs as llamaCppMtpPkgs and consumed only by
      # hosts/zen3-nixos/ai/llama-swap.nix (llamaCmdR9700Flash / r9700 router).
      llamaCppMtpPkgs = builtins.mapAttrs (
        _: pkg:
        pkg.overrideAttrs (old: {
          cmakeFlags = old.cmakeFlags ++ [ "-DLLAMA_BUILD_TESTS=OFF" ];
        })
      ) llama-cpp-mtp.packages.${system};

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
            inherit llamaCppPkgs;
            inherit llamaCppMtpPkgs;
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
