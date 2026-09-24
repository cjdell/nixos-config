# Installs `klipper-firmware-update` on 3d-printer-server -- rebuilds the
# Smoothieboard's Klipper MCU firmware at the same version the running klipper
# container is using (the container tracks the floating `latest` tag, the MCU
# firmware is flashed by hand, so the two drift apart silently).
#
# See the script header for the board details (LPC1768, USB, 16KiB
# Smoothieware/DFU bootloader) and the build-config rationale.
{ pkgs, ... }:

let
  klipper-firmware-update = pkgs.writeShellApplication {
    name = "klipper-firmware-update";
    # writeShellApplication puts these on PATH *inside* the script, so they
    # survive `sudo` (which would otherwise reset PATH via secure_path).
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      podman
    ];
    text = builtins.readFile ./klipper-firmware-update.sh;
  };
in
{
  environment.systemPackages = [ klipper-firmware-update ];
}
