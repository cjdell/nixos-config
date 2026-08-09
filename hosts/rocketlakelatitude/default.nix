{ home-manager, ... }:

[
  ../../common/desktop.nix
  ../../common/podman.nix
  ../../common/system.nix
  ../../users/cjdell

  ({ lib, pkgs, ... }: {
    imports = [
      ./ardour.nix
      ./hardware-configuration.nix
    ];

    services.udev.packages = [
      pkgs.platformio-core
      pkgs.openocd
    ];

    # USB access stuff
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}="1a86", ATTR{idProduct}=="8010", GROUP="plugdev"
      SUBSYSTEM=="usb", ATTR{idVendor}="4348", ATTR{idProduct}=="55e0", GROUP="plugdev"
      SUBSYSTEM=="usb", ATTR{idVendor}="1a86", ATTR{idProduct}=="8012", GROUP="plugdev"
    '';
    users.groups.plugdev.members = [ "cjdell" ];
    users.groups.plugdev = { };

    environment.systemPackages = with pkgs; [
      binutils
      gnumake
      clang
      jq

      gcc
      probe-rs-tools
      wlink

      crosspipe
    ];

    nixpkgs.overlays = [
      (final: prev: {
        vscode = prev.vscode.overrideAttrs (
          oldAttrs:
          let
            codelldb = final.vscode-extensions.vadimcn.vscode-lldb;
          in
          rec {
            additionalLibs = with prev; [
              zlib # Required by CodeLLDB
            ];

            patchCodeLLVM = prev.writeScript "patchCodeLLVM.sh" ''
              #!/usr/bin/env bash
              find ~/.vscode/extensions/ \
                -name codelldb \
                -type f -or -type l \
                -exec sh -c 'rm -f "$1" && ln -s "${codelldb}/${codelldb.installPrefix}/adapter/codelldb" "$1"' _ "{}" \;
            '';

            postInstall = oldAttrs.postInstall or "" + ''
              # Create a wrapper script for VSCode
              wrapProgram "$out/bin/code" \
                --run ${patchCodeLLVM} \
                --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath additionalLibs}"
            '';
          }
        );
      })
      (final: prev: {
        vscode-extensions.vadimcn.vscode-lldb =
          prev.vscode-extensions.vadimcn.vscode-lldb.overrideAttrs
            (oldAttrs: rec {
              src = prev.fetchFromGitHub {
                owner = "vadimcn";
                repo = "vscode-lldb";
                # gha-updater: LATEST="$(curl -Ls https://api.github.com/repos/vadimcn/vscode-lldb/releases/latest)" && echo -n "$(echo $LATEST | jq -jr .tag_name) $(nix-prefetch-url --unpack $(echo $LATEST | jq -jr .tarball_url))"
                rev = "v1.12.2";
                sha256 = "1889bp778y5b29v1dd7cygnjsaxn7j1sc0yhg1l3jz5b9p5zxzzg";
              };
              version = lib.substring 1 20 src.rev;
            });
      })
    ];

    users.users.testuser = {
      isNormalUser = true;
    };

    home-manager.users.testuser = {
      home.stateVersion = "26.05";

      programs.git = {
        enable = true;
        settings = {
          user.name = "Chris Dell";
          user.email = "cjdell@gmail.com";
          init.defaultBranch = "main";
        };
      };
    };
  })
]
