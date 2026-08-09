{
  imports = [
    ./nix.nix
    # Only configure Plasma when the system actually runs it. Hosts using a
    # different desktop (e.g. GNOME) or no desktop at all would otherwise still
    # get KDE config files written into the home directory.
    ({ config, ... }: {
      home-manager.users.cjdell.programs.plasma.enable = config.services.desktopManager.plasma6.enable;
    })
  ];
  home-manager.users.cjdell = import ./home.nix;
}
