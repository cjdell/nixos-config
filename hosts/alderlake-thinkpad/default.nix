{ sops-nix, ... }:

[
  sops-nix.nixosModules.sops

  ../../common/gnome.nix
  ../../common/podman.nix
  ../../common/printer.nix
  ../../common/sops.nix
  ../../common/system.nix
  ../../users/cjdell

  ./tailscale.nix

  ({ lib, pkgs, ... }: {
    imports = [
      ./ai.nix
      ./hardware-configuration.nix
    ];

    # Use the Zen 3 workstation (zen3-nixos, 192.168.49.50) as a remote Nix
    # build machine, so heavy derivations build there instead of on this laptop.
    nix.distributedBuilds = true;
    nix.buildMachines = [
      {
        hostName = "192.168.49.50";
        protocol = "ssh-ng";
        sshUser = "root";
        sshKey = "/root/.ssh/id_ed25519";
        system = "x86_64-linux";
        maxJobs = 16;
        speedFactor = 4;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
        ];
      }
    ];
    # Pin the builder's SSH host key so ssh-ng connects without a prompt.
    programs.ssh.knownHosts."192.168.49.50" = {
      hostNames = [ "192.168.49.50" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFdeRHV02KmEdG3YoH2aq1++9PqeTwGlWUsG0XKzUE27";
    };

    services.fprintd.enable = true;

    sops.secrets.tailscale_pre_auth_key = { };

    services.displayManager.autoLogin.enable = lib.mkForce false;

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

      rustup
      cargo-binutils
      gcc
      probe-rs-tools
      wlink

      nodejs
    ];

    programs.steam.enable = true;

    # programs.zed-editor = {
    #   enable = true;
    #   load_direnv = "shell_hook";
    # };
  })

  # This machine runs GNOME, but ~/.config still carries GTK settings written by
  # KDE Plasma's kde-gtk-config during the initial setup (Aug 2026), pointing at
  # the Breeze icon/cursor themes which are not installed here. That left GNOME
  # with a fallback (white square) cursor and missing window-decoration icons.
  # Point GTK/GNOME at the installed Adwaita theme instead and neutralise the
  # stale KDE GTK files.
  {
    home-manager.users.cjdell = {
      gtk = {
        enable = true;
        theme.name = "Adwaita";
        iconTheme.name = "Adwaita";
        cursorTheme.name = "Adwaita";
        # The gtk module manages ~/.gtkrc-2.0, which still holds stale KDE
        # (Breeze) settings from the initial Plasma setup. Force-overwrite it
        # or home-manager activation fails with "would be clobbered".
        gtk2.force = true;
      };

      dconf.settings."org/gnome/desktop/interface" = {
        cursor-theme = "Adwaita";
        icon-theme = "Adwaita";
        gtk-theme = "Adwaita";
      };

      # Remove stale KDE-generated GTK files (settings.ini is managed by the gtk
      # module above; these are not).
      home.file = {
        ".config/gtkrc" = {
          text = "";
          force = true;
        };
        ".config/gtkrc-2.0" = {
          text = "";
          force = true;
        };
        ".config/gtk-3.0/gtk.css" = {
          text = "";
          force = true;
        };
        ".config/gtk-3.0/colors.css" = {
          text = "";
          force = true;
        };
        ".config/gtk-4.0/gtk.css" = {
          text = "";
          force = true;
        };
        ".config/gtk-4.0/colors.css" = {
          text = "";
          force = true;
        };
      };
    };
  }
]
