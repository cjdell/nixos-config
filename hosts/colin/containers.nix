{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  constants = import ../constants.nix;
  update-containers = (
    pkgs.writeShellScriptBin "update-containers" ''
      SUDO=""
      if [[ $(id -u) -ne 0 ]]; then
        SUDO="sudo"
      fi

      images=$($SUDO ${pkgs.podman}/bin/podman ps -a --format="{{.Image}}" | sort -u)

      for image in $images
      do
        $SUDO ${pkgs.podman}/bin/podman pull $image
      done

      ${pkgs.systemd}/bin/systemctl restart podman-*
    ''
  );
in
{
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    # defaultNetwork.settings.dns_enabled = true;
    defaultNetwork.settings.ipv6_enabled = true;
  };

  virtualisation.containers.containersConf.settings.containers.umask = "0002";

  virtualisation.oci-containers.backend = "podman";

  environment.systemPackages = [
    update-containers
  ];

  systemd.timers = {
    update-containers = {
      timerConfig = {
        Unit = "update-containers.service";
        OnCalendar = "Mon 02:00";
      };
      wantedBy = [ "timers.target" ];
    };
  };
  systemd.services = {
    update-containers = {
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${update-containers}/bin/update-containers";
      };
    };
  };
}
