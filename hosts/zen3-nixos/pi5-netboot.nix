# Serves the Raspberry Pi 5's netboot files declaratively.
#
# The RPi 5 eeprom TFTP-fetches e9cf02dc/{config.txt,dtb,cmdline.txt,Image,
# initrd,armstub8-2712.bin} from this host (the tftpd unit lives in
# ./netboot.nix). The bundle is built by the gc-rust-node flake's
# parameterized `lib.mkPi5Netboot`, which takes THIS host's deployment
# values (services.pi5Netboot.* in ./pi5-deploy.nix) — the template itself
# contains no deployment values. The bundle holds the complete eeprom boot
# dir PLUS the Pi's Nix store (nixStore/, built by make-store-dir.nix: full
# toplevel closure + nix-path-registration). We bind-mount both halves here:
#
#   /etc/tftp/e9cf02dc   -> eeprom boot dir (TFTP)
#   /exports/nix-store   -> the Pi's store snapshot (NFSv4, client name :/nix-store)
#
# The store served to the Pi is the BUNDLE's snapshot, deliberately NOT this
# host's own /nix/store: the bundle is fully self-contained, so the Pi is
# decoupled from this host's store contents and GC. The export root contains
# nix-path-registration, which the Pi's postBootCommands reads for
# `nix-store --load-db`. Both bind sources are GC-pinned: the fstab carries
# the literal store path and lives in the system generation's closure.
#
# The NFS export (netboot.nix) is the fsid=0 /exports root with `crossmnt` —
# deliberately NO /exports/nix-store sub-export: an export entry would pin
# this bind mount and make `nixos-rebuild switch` fail to restart it
# ("Failed to restart exports-nix\x2dstore.mount", exit 4).
#
# Deploying a Pi update therefore == `nixos-rebuild switch` on this host
# (autoRollback is on, so finish with `sudo nixos-confirm`) followed by a Pi
# power-cycle — scripts/update-pi5-node.sh does the whole loop.
{
  lib,
  pkgs,
  inputs,
  config,
  ...
}:

let
  pi5Netboot = inputs.gc-rust-node.lib.mkPi5Netboot {
    inherit (config.services.pi5Netboot) nfsServer grpcAddr joinCode;
  };
in
{
  # Handy handle for a manual root build of just the bundle:
  #   sudo nix build '.#nixosConfigurations.zen3-nixos.config.system.build.pi5Netboot'
  system.build.pi5Netboot = pi5Netboot;

  fileSystems."/etc/tftp/e9cf02dc" = {
    device = "${pi5Netboot}";
    fsType = "none";
    options = [ "bind" ];
  };

  fileSystems."/exports/nix-store" = {
    device = "${pi5Netboot}/nixStore/nix-store";
    fsType = "none";
    options = [ "bind" ];
  };
}
