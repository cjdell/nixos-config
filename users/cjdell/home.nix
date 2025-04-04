{ pkgs, ... }: {
  home.stateVersion = "24.11";

  programs.git = {
    enable = true;
    userName = "Chris Dell";
    userEmail = "cjdell@gmail.com";
    extraConfig = {
      init.defaultBranch = "main";
    };
  };

  programs.plasma = {
    enable = true;

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
          idleTimeout = "never";
        };
        dimDisplay = {
          idleTimeout = null;
        };
        displayBrightness = 100;
        powerProfile = "performance";
      };
    };
  };
}
