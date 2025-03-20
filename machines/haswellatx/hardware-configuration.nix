# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [
      (modulesPath + "/installer/scan/not-detected.nix")
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # boot.loader.grub.enable = true;
  # boot.loader.grub.device = "/dev/sda";
  # boot.loader.grub.useOSProber = true;

  # boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  boot.kernelParams = [
    "mitigations=off"
    "radeon.cik_support=0"
    "amdgpu.cik_support=1"
  ];

  hardware.amdgpu.opencl.enable = true;

  services.xserver.videoDrivers = [ "amdgpu" ];

  hardware.graphics =
    let
      intel-vaapi-driver = pkgs.intel-vaapi-driver.override { enableHybridCodec = true; };
      # fn = oa: {
      #   nativeBuildInputs = oa.nativeBuildInputs ++ [ pkgs.glslang ];
      #   mesonFlags = oa.mesonFlags ++ [ "-Dvulkan-layers=device-select,overlay" ];
      #   postInstall = oa.postInstall + ''
      #     mv $out/lib/libVkLayer* $drivers/lib

      #     #Device Select layer
      #     layer=VkLayer_MESA_device_select
      #     substituteInPlace $drivers/share/vulkan/implicit_layer.d/''${layer}.json \
      #       --replace "lib''${layer}" "$drivers/lib/lib''${layer}"

      #     #Overlay layer
      #     layer=VkLayer_MESA_overlay
      #     substituteInPlace $drivers/share/vulkan/explicit_layer.d/''${layer}.json \
      #       --replace "lib''${layer}" "$drivers/lib/lib''${layer}"
      #   '';
      # };
    in
    {
      enable = true;
      enable32Bit = true;
      extraPackages = [
        pkgs.intel-media-driver # LIBVA_DRIVER_NAME=iHD
        intel-vaapi-driver # LIBVA_DRIVER_NAME=i965 (older but works better for Firefox/Chromium)
        pkgs.libvdpau-va-gl
        # pkgs.ocl-icd
        # pkgs.mesa.opencl
        # (pkgs.mesa.overrideAttrs fn).drivers
      ];
      # package32 = (pkgsi686Linux.mesa.overrideAttrs fn).drivers;
    };

  # environment.sessionVariables = { LIBVA_DRIVER_NAME = "iHD"; }; # Force intel-media-driver

  fileSystems."/" =
    {
      device = "/dev/disk/by-uuid/e5ca02f2-0233-4ce3-bb0e-e8a4b44215b3";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    {
      device = "/dev/disk/by-label/BOOT";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };

  swapDevices =
    [
      { device = "/dev/disk/by-uuid/e1ae3298-c096-4fa1-8280-78aa72eacc94"; }
    ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp2s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
