{ pkgs, ... }:

# cjdell's home-manager profile on the router. Unlike the other hosts this
# does NOT import users/cjdell/home.nix (that carries the desktop/Plasma
# profile); the router gets only the fleet-wide opencode config, so the router
# matches the rest of the fleet. Everything else in $HOME stays unmanaged.
{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.cjdell = {
      home.stateVersion = "24.11";

      # npx for the brave-search MCP server in opencode.json (the other hosts
      # get nodejs from users/cjdell/home.nix).
      home.packages = [ pkgs.nodejs ];

      imports = [ ../../users/cjdell/opencode.nix ];
    };
  };
}
