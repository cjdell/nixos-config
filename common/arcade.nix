{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # emulationstation-de

    # (retroarch.override {
    #   cores = with libretro; [
    #     genesis-plus-gx
    #     snes9x
    #     beetle-psx-hw
    #   ];
    # })
  ];

  # system.activationScripts.arcade = ''
  #   mkdir -p /home/user/Applications
  #   ${pkgs.wget}/bin/wget -O /home/user/Applications/RetroArch-Linux-x86_64.AppImage  https://github.com/hizzlekizzle/RetroArch-AppImage/releases/download/Linux_LTS_Nightlies/RetroArch-Linux-x86_64-Nightly.AppImage
  #   ${pkgs.wget}/bin/wget -O /home/user/Applications/RetroArch.AppImage.home.7z       https://github.com/hizzlekizzle/RetroArch-AppImage/releases/download/Nightlies/RetroArch-Linux-x86_64-Nightly.AppImage.home.7z
  #   ${pkgs.wget}/bin/wget -O /home/user/Applications/ES-DE.AppImage                   https://gitlab.com/es-de/emulationstation-de/-/package_files/164503027/download

  #   mkdir -p /home/user/tmp
  #   mkdir -p /home/user/.config
  #   ${pkgs.p7zip}/bin/7za x -y /home/user/Applications/RetroArch.AppImage.home.7z -o/home/user/tmp
  #   mv /home/user/tmp/RetroArch-Linux-x86_64-Nightly.AppImage.home/retroarch /home/user/.config
  #   rm -rf /home/user/tmp

  #   chmod +x            /home/user/Applications/*
  #   chown -R user:users /home/user/Applications
  #   chown -R user:users /home/user/.config

  #   cp ./files/start.sh         ~
  #   cp ./files/start.sh.desktop ~/.config/autostart

  # '';
}
