{ options, ... }:

{
  # sudo systemctl start syncoid-ds-photos
  # journalctl -u syncoid-ds-photos -f

  # sudo systemctl start syncoid-ds-media
  # journalctl -u syncoid-ds-media -f

  services.syncoid = {
    enable = true;
    interval = "*:35"; # run this less often than sanoid (every hour at 35 mins)
    #commonArgs = [ "--debug" ];
    commands = {
      "ds-photos" = {
        sshKey = "/var/lib/syncoid/backup.key";
        source = "samsung-4tb/ds-photos";
        target = "backup@dbthr33-server.grafton.tailscale:dbthr33/ds-external-backups/ds-grafton/ds-photos";
        sendOptions = "w c";
        extraArgs = [ "--sshoption=StrictHostKeyChecking=off" ];
      };
      "ds-media" = {
        sshKey = "/var/lib/syncoid/backup.key";
        source = "samsung-4tb/ds-media";
        target = "backup@n40l-nas.grafton.tailscale:sas-16tb/ds-external-backups/ds-samsung-4tb/ds-media";
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
