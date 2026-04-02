{ options, ... }:

{
  services.sanoid = {
    enable = true;
    #extraArgs = [ "--debug" ];
    interval = "*:2,32"; # run this more often than syncoid (every 30 mins)
    datasets = {
      # https://github.com/jimsalterjrs/sanoid/wiki/Syncoid#snapshot-management-with-sanoid
      "sas-24tb/ds-public" = {
        autoprune = true;
        autosnap = true;
        hourly = 4;
        daily = 7;
        weekly = 4;
        monthly = 12;
        yearly = 0;
      };
    };
  };

  system.activationScripts.installBackupKey = ''
    chmod 0400 /var/lib/syncoid/backup.key
  '';

  # sudo systemctl start syncoid-ds-public
  # journalctl -u syncoid-ds-public -f

  # sudo systemctl start syncoid-ds-cjdell
  # journalctl -u syncoid-ds-cjdell -f

  services.syncoid = {
    enable = true;
    interval = "*:35"; # run this less often than sanoid (every hour at 35 mins)
    #commonArgs = [ "--debug" ];
    commands = {
      "ds-public" = {
        sshKey = "/var/lib/syncoid/backup.key";
        source = "sas-24tb/ds-public";
        target = "backup@n40l-nas.grafton.tailscale:sas-16tb/ds-external-backups/ds-sas-24tb/ds-public";
        sendOptions = "w c";
        extraArgs = [ "--sshoption=StrictHostKeyChecking=off" ];
      };
      "ds-cjdell" = {
        sshKey = "/var/lib/syncoid/backup.key";
        source = "sas-24tb/ds-cjdell";
        target = "backup@n40l-nas.grafton.tailscale:sas-16tb/ds-external-backups/ds-sas-24tb/ds-cjdell";
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
