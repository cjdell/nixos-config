# Serves the Raspberry Pi 5's netboot files declaratively.
#
# The RPi 5 eeprom TFTP-fetches e9cf02dc/{config.txt,dtb,cmdline.txt,Image,
# initrd,armstub8-2712.bin} from this host (the tftpd unit lives in
# ./netboot.nix). Those files are built by the gc-rust-node flake's
# pi5-netboot package — the complete boot dir plus the NFS-served nixStore/
# (see ~/Projects/gc-business/gc-rust-node, flake.nix + pi5/). We bind-mount
# that store path here, so /etc/tftp/e9cf02dc is always the current bundle.
#
# Deploying a Pi update therefore == `nixos-rebuild switch` on this host
# (autoRollback is on, so finish with `sudo nixos-confirm`) followed by a Pi
# power-cycle — scripts/update-pi5-node.sh does the whole loop.
{ lib, pkgs, inputs, ... }:

let
  pi5Netboot = inputs.gc-rust-node.packages.aarch64-linux.pi5-netboot;
in
{
  # The pi5-netboot output is read-only and GC-pinned by the system closure
  # (it is the mount source). The NFS-served nixStore/ (the Pi's read-only
  # /nix/.ro-store) is this host's own /nix/store via netboot.nix, so nothing
  # else needs copying.
  fileSystems."/etc/tftp/e9cf02dc" = {
    device = "${pi5Netboot}";
    fsType = "none";
    options = [ "bind" ];
  };
}
