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
}
