{
  config,
  lib,
  pkgs,
  ...
}:

{
  home.stateVersion = "24.11";

  # Node.js lives in the user profile (home-manager), not in the system
  # closure, so it can be updated/removed without a full system rebuild.
  home.packages = [ pkgs.nodejs ];

  # npm's default global prefix is node's own directory, which is a
  # read-only /nix/store path, so `npm install -g` fails with EACCES.
  # Point it at $HOME/.local instead; its bin/ is already on PATH.
  home.file.".npmrc".text = ''
    prefix=${config.home.homeDirectory}/.local
  '';

  programs.git = {
    enable = true;
    settings = {
      user.name = "Chris Dell";
      user.email = "cjdell@gmail.com";
      init.defaultBranch = "main";
    };
  };

  programs.plasma = {
    # Only enabled when the host actually runs Plasma — users/cjdell/default.nix
    # overrides this with services.desktopManager.plasma6.enable.
    enable = lib.mkDefault true;

    kscreenlocker = {
      autoLock = false;
    };

    powerdevil = {
      AC = {
        powerButtonAction = "shutDown";
        autoSuspend = {
          action = "nothing";
        };
        turnOffDisplay = {
          idleTimeout = 300;
          # idleTimeout = "never";
        };
        # dimDisplay = {
        #   idleTimeout = null;
        # };
        displayBrightness = 100;
        powerProfile = "performance";
      };
    };

    session = {
      general = {
        askForConfirmationOnLogout = false;
      };
      sessionRestore = {
        restoreOpenApplicationsOnLogin = "startWithEmptySession";
      };
    };

    configFile = {
      baloofilerc."Basic Settings"."Indexing-Enabled" = false;
    };
  };
}
