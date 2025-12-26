{
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
  };

  networking.firewall.interfaces.podman0.allowedUDPPorts = [ 53 ];

  system.updateContainers = {
    enable = true;
    webhookUrl = "https://notify.home.chrisdell.info";
  };

  # Enable common container config files in /etc/containers
  virtualisation.containers.enable = true;

  virtualisation.oci-containers.backend = "podman";
}
