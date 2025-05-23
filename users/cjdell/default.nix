{ config, pkgs, ... }:

{
  home-manager.users.cjdell = import ./home.nix;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.cjdell = {
    uid = 1000;
    isNormalUser = true;
    description = "Chris Dell";
    extraGroups = [ "networkmanager" "wheel" "dialout" ];
    packages = with pkgs; [ ];
    openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCbDJ7tQwODw2kx2f1bstOUElKnaR3hP2RbwCsf6zebZ5n/1CFUoM2Ye78D/IG/6kgDc22wD9EkzyvIwF/96fp3IgxK5ja/Q0pEhbd8xAPGIpFC7BUyePqozRusSvJXl7RamBb8lgsjySQxJxYX9MQzbQkfasWOwWE+WWqiC9nwk6WiER7EraOdEVNNF9cuNS/LVFrQZG5xdzI5gSgaxth2kQSgE3z7jIIvmlYkChEjTMXSQt9MrluhWB1nzGDHVrcqW8uu/jAqeMhRCXP39wtmL21v3WFn1jwDQlOgbR1CxnBzy+jE62TqvOJg8x6/J2WC/VXcdndHq1vKYP0s5mQn cjdell@gmail.com" ];
  };

  # Enable automatic login for the user.
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "cjdell";

  users.groups.libvirtd.members = [ "cjdell" ];

  system.activationScripts.homeDir = ''
    usermod -u 1000 cjdell
    chown -R 1000 /home/cjdell
  '';

  # Allow launching of remote X11 apps on this display
  system.activationScripts.xhostConfig = ''
    mkdir -p /home/cjdell/.config/autostart
    echo "#!/usr/bin/env bash"                >   /home/cjdell/xhost-config.sh
    echo "${pkgs.xorg.xhost}/bin/xhost +"     >>  /home/cjdell/xhost-config.sh
    chmod +x                                      /home/cjdell/xhost-config.sh
    chown cjdell:users                            /home/cjdell/xhost-config.sh

    echo "[Desktop Entry]"                    >   /home/cjdell/.config/autostart/xhost-config.sh.desktop
    echo "Exec=/home/cjdell/xhost-config.sh"  >>  /home/cjdell/.config/autostart/xhost-config.sh.desktop
    echo "Icon=application-x-shellscript"     >>  /home/cjdell/.config/autostart/xhost-config.sh.desktop
    echo "Name=xhost-config.sh"               >>  /home/cjdell/.config/autostart/xhost-config.sh.desktop
    echo "Type=Application"                   >>  /home/cjdell/.config/autostart/xhost-config.sh.desktop
    echo "X-KDE-AutostartScript=true"         >>  /home/cjdell/.config/autostart/xhost-config.sh.desktop

    chmod 600                                     /home/cjdell/.config/autostart/xhost-config.sh.desktop
    chown -R cjdell:users                         /home/cjdell/.config/autostart
  '';
}
