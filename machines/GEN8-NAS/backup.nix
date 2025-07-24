{
  config,
  lib,
  pkgs,
  modulesPath,
  options,
  ...
}:

{
  services.sanoid = {
    enable = true;
    #extraArgs = [ "--debug" ];
    interval = "*:2,32"; # run this more often than syncoid (every 30 mins)
    datasets = {
      # https://github.com/jimsalterjrs/sanoid/wiki/Syncoid#snapshot-management-with-sanoid
      "sas-16tb/ds-public" = {
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

  # services.syncoid = {
  #   enable = true;
  #   interval = "*:35"; # run this less often than sanoid (every hour at 35 mins)
  #   #commonArgs = [ "--debug" ];
  #   commands = {
  #     "ds-public" = {
  #       sshKey = "/var/lib/syncoid/backup.key";
  #       source = "sas-16tb/ds-public";
  #       target = "backup@10.47.35.20:dbthr33/ds-external-backups/grafton";
  #       sendOptions = "w c";
  #       extraArgs = [ "--sshoption=StrictHostKeyChecking=off" ];
  #     };
  #   };
  #   localSourceAllow = options.services.syncoid.localSourceAllow.default ++ [
  #     "mount"
  #   ];
  #   localTargetAllow = options.services.syncoid.localTargetAllow.default ++ [
  #     "destroy"
  #   ];
  # };
}
