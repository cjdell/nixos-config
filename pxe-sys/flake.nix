{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }@inputs:
    {
      nixosConfigurations.pxeclient =
        let
          nfsServer = "192.168.49.50";
          system = "x86_64-linux";
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
            };
          };
        in
        nixpkgs.lib.nixosSystem {
          inherit pkgs;
          system = "x86_64-linux";
          modules = [
            ./configuration.nix
            ((import ./netboot.nix) { inherit nfsServer; })
          ];
        };
    };
}
