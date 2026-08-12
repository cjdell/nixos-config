{ pkgs, lib, ... }:
{
  home.stateVersion = "24.11";

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
