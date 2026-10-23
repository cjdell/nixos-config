{ options, ... }:

{
  # sudo systemctl start syncoid-ds-photos
  # journalctl -u syncoid-ds-photos -f

  # sudo systemctl start syncoid-ds-media
  # journalctl -u syncoid-ds-media -f

  # sudo systemctl start syncoid-ds-db-backups
  # journalctl -u syncoid-ds-db-backups -f

  # SQL dumps from the database services (the immich pg_dump in postgres.nix
  # and the christcentralpreston mysqldump in christcentralpreston.nix) live on
  # their own dataset — ds-photos is for photos only — and ride this job to
  # N40L-NAS alongside ds-media.
  disko.zfs = {
    enable = true;
    settings.datasets."samsung-4tb/ds-db-backups" = { };
  };

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
      # SQL dumps dataset (see above); syncoid creates the target dataset.
      "ds-db-backups" = {
        sshKey = "/var/lib/syncoid/backup.key";
        source = "samsung-4tb/ds-db-backups";
        target = "backup@n40l-nas.grafton.tailscale:sas-16tb/ds-external-backups/ds-samsung-4tb/ds-db-backups";
        sendOptions = "w c";
        extraArgs = [ "--sshoption=StrictHostKeyChecking=off" ];
      };
      # christcentralpreston.co.uk site tree (its own dataset, see
      # christcentralpreston.nix); syncoid creates the target dataset.
      "ds-christcentralpreston" = {
        sshKey = "/var/lib/syncoid/backup.key";
        source = "samsung-4tb/ds-christcentralpreston";
        target = "backup@n40l-nas.grafton.tailscale:sas-16tb/ds-external-backups/ds-samsung-4tb/ds-christcentralpreston";
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
