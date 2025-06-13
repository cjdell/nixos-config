{ config, pkgs, ... }:

{
  services.foldingathome = {
    enable = true;
    user = "cjdell";
    team = 236565;
    extraArgs = [
      "--http-addresses=0.0.0.0:7396"
      "--allow=0/0"
    ];
  };
}
