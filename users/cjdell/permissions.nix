{ config, pkgs, ... }:

{
  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.cjdell = {
    isNormalUser = true;
    description = "Chris Dell";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [ ];
    openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCbDJ7tQwODw2kx2f1bstOUElKnaR3hP2RbwCsf6zebZ5n/1CFUoM2Ye78D/IG/6kgDc22wD9EkzyvIwF/96fp3IgxK5ja/Q0pEhbd8xAPGIpFC7BUyePqozRusSvJXl7RamBb8lgsjySQxJxYX9MQzbQkfasWOwWE+WWqiC9nwk6WiER7EraOdEVNNF9cuNS/LVFrQZG5xdzI5gSgaxth2kQSgE3z7jIIvmlYkChEjTMXSQt9MrluhWB1nzGDHVrcqW8uu/jAqeMhRCXP39wtmL21v3WFn1jwDQlOgbR1CxnBzy+jE62TqvOJg8x6/J2WC/VXcdndHq1vKYP0s5mQn cjdell@gmail.com" ];
  };

  # Enable automatic login for the user.
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "cjdell";

  users.groups.libvirtd.members = [ "cjdell" ];

  # Allow launching of remote X11 apps on this display
  system.activationScripts.xhostConfig = ''
    mkdir -p /home/cjdell/.config/autostart
    echo "#!/usr/bin/env bash"                >   /home/cjdell/xhost-config.sh
    echo "${pkgs.xorg.xhost}/bin/xhost +"     >>  /home/cjdell/xhost-config.sh
    chmod +x                                      /home/cjdell/xhost-config.sh
    chown cjdell:users                            /home/cjdell/xhost-config.sh

    echo "[Desktop Entry]"                    >   /home/cjdell/.config/autostart/xhost-config.desktop
    echo "Comment[en_GB]="                    >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "Comment="                           >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "Exec=/home/cjdell/xhost-config"     >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "GenericName[en_GB]="                >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "GenericName="                       >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "MimeType="                          >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "Name[en_GB]=xhost-config"           >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "Name=xhost-config"                  >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "NoDisplay=false"                    >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "Path="                              >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "StartupNotify=true"                 >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "Terminal=false"                     >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "TerminalOptions="                   >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "Type=Application"                   >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "X-KDE-SubstituteUID=false"          >>  /home/cjdell/.config/autostart/xhost-config.desktop
    echo "X-KDE-Username="                    >>  /home/cjdell/.config/autostart/xhost-config.desktop

    chmod 600                                     /home/cjdell/.config/autostart/xhost-config.desktop
    chown -R cjdell:users                         /home/cjdell/.config/autostart
  '';
}
