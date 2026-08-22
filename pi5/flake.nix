# Minimal network-bootable NixOS for a Raspberry Pi 5 (aarch64-linux) with SSH.
#
# Built natively on an aarch64 machine (MacBookAir-NixOS) and served for
# network boot by zen3: the RPi 5 EEPROM TFTP-fetches config.txt, the dtb,
# cmdline.txt, the kernel (Image) and the small initrd; the Nix store is
# mounted from zen3 over NFSv4 (/exports/nix-store, see configuration.nix).
{
  description = "Raspberry Pi 5 netboot (aarch64) NixOS with SSH, NFS root from zen3";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, nixos-hardware }@inputs:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
      };
      cfg = self.nixosConfigurations.pi5.config;
    in
    {
      nixosConfigurations.pi5 = nixpkgs.lib.nixosSystem {
        inherit system pkgs;
        modules = [
          ./configuration.nix
          # Correct linux-rpi kernel (bcm2712 defconfig) + Pi 5 initrd modules
          # (macb GbE, rp1, pcie-brcmstb, clk-rp1) + bcm2712 dtb selection.
          nixos-hardware.nixosModules.raspberry-pi-5
        ];
      };

      # Netboot artifacts for zen3 to serve (see hosts/zen3-nixos/pi5-netboot.nix):
      #   kernel  -> cfg.boot.kernelPackage/Image  (TFTP, 38.5 MB, < 30 s)
      #   initrd  -> cfg.system.build.toplevel/initrd (TFTP, few MB)
      #   store   -> cfg.system.build.nixStore/nix-store (NFS at /exports/nix-store)
      packages."${system}".pi5-netboot = pkgs.runCommandLocal "pi5-netboot" { } ''
        mkdir -p $out
        cp -L ${cfg.system.build.toplevel}/kernel $out/Image
        cp ${cfg.system.build.toplevel}/initrd $out/initrd
        cp ${cfg.system.build.toplevel}/init $out/init
        cp -a ${cfg.system.build.nixStore} $out/nixStore
      '';
    };
}
