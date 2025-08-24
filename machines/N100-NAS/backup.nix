{
  config,
  lib,
  pkgs,
  modulesPath,
  options,
  ...
}:

{
  services.syncoid = {
    enable = true;
    interval = "*:35"; # run this less often than sanoid (every hour at 35 mins)
    #commonArgs = [ "--debug" ];
    commands = {
      "ds-photos" = {
        sshKey = "/var/lib/syncoid/backup.key";
        source = "samsung-4tb/ds-photos";
        target = "backup@10.47.35.20:dbthr33/ds-external-backups/ds-grafton/ds-photos";
        sendOptions = "w c";
        extraArgs = [ "--sshoption=StrictHostKeyChecking=off" ];
      };
    };
    localSourceAllow = options.services.syncoid.localSourceAllow.default ++ [
      "mount"
    ];
    localTargetAllow = options.services.syncoid.localTargetAllow.default ++ [
      "destroy"
    ];
  };
}
