{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  POOL_NAME = "sas-16tb";
  HOME_DIR = "/var/lib/backup";
in
{
  # Define a user account.
  users.users.backup = {
    uid = 999999;
    # isSystemUser = true;  # This didn't work
    isNormalUser = true;
    createHome = true;
    home = HOME_DIR;
    group = "backup";
    extraGroups = [ ];
    openssh = {
      # https://stackoverflow.com/a/50400836 ; prevent
      # ssh backup@optinix.local -t "bash --noprofile" via no-pty
      authorizedKeys.keys = [
        "no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGgFpQXfFVqlNRs6L17SGIpkjvXqNPQN5dwA1frOk2G backup@shared"
      ];
    };
  };

  users.groups.backup = { 
    gid = 999999;
  };

  nix.settings.trusted-users = [ "backup" ];

  systemd.services.backup-permissions =
  {
    script = ''
      ${pkgs.coreutils-full}/bin/mkdir -p ${HOME_DIR}
      ${pkgs.coreutils-full}/bin/chown -R backup:backup ${HOME_DIR}

      ${pkgs.zfs}/bin/zfs allow backup create,mount,destroy,receive ${POOL_NAME}
    '';
    requiredBy = [ "home-manager-backup.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
  };

  home-manager.users.backup =
    { config, ... }:
    {
      home.stateVersion = "23.11";
      home.username = "backup";
      home.homeDirectory = HOME_DIR;

      home.file.".bash_profile" = {
        executable = true;
        text = ''
          export PATH=$HOME/bin
        '';
      };
      home.file.".bashrc" = {
        executable = true;
        text = ''
          export PATH=$HOME/bin
        '';
      };
      home.file.".profile" = {
        executable = true;
        text = ''
          export PATH=$HOME/bin
        '';
      };
      home.file.".bash_login" = {
        executable = true;
        text = ''
          export PATH=$HOME/bin
        '';
      };
      # https://www.reddit.com/r/NixOS/comments/v0eak7/homemanager_how_to_create_symlink_to/
      home.file."bin/lzop".source = config.lib.file.mkOutOfStoreSymlink "${pkgs.lzop}/bin/lzop";
      home.file."bin/mbuffer".source = config.lib.file.mkOutOfStoreSymlink "${pkgs.mbuffer}/bin/mbuffer";
      home.file."bin/pv".source = config.lib.file.mkOutOfStoreSymlink "${pkgs.pv}/bin/pv";
      home.file."bin/zfs".source = config.lib.file.mkOutOfStoreSymlink "${pkgs.zfs}/bin/zfs";
      home.file."bin/zpool".source = config.lib.file.mkOutOfStoreSymlink "${pkgs.zfs}/bin/zpool";
      home.file."bin/zstd".source = config.lib.file.mkOutOfStoreSymlink "${pkgs.zstd}/bin/zstd";
      home.file."bin/ps".source = config.lib.file.mkOutOfStoreSymlink "${pkgs.procps}/bin/ps";
    };
}
