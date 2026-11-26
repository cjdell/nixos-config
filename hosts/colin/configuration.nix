# colin's host-specific configuration.
#
# Fleet-wide settings (ssh, sudo, nix-ld, locale, time zone, stateVersion,
# firewall, the CLI toolset) now come from common/system.nix + users/cjdell via
# flake.nix's mkHost — do not restate them here. This file is only what is true
# of this machine.

{ pkgs, ... }:

let
  constants = import ./constants.nix;
in
{
  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # 26.11 warns (and will later default to false) that root should not be
  # force-imported at each boot: / is ext4 here and the electronerds pool is
  # imported by its own mount units (boot.zfs.extraPools lives in
  # hardware-configuration.nix), so there is nothing to wait for. Set
  # deliberately rather than leaving the eval warning.
  boot.zfs.forceImportRoot = false;

  # This box is a server, not a laptop: nothing should ever suspend it.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # filebrowser/AdGuard/… containers run as fixed UIDs (see constants.nix);
  # admin is the human account that owns /srv.
  users.users.admin = {
    uid = constants.ADMIN_UID;
    group = "users";
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  # cjdell's account (uid 1000, wheel, the ssh keys) comes from users/cjdell.

  # The fleet CLI set is sharedPackages (common/system.nix). What is left here
  # is the colin-only extras: the editor, the disk/network forensics tools and
  # the pool maintenance commands.
  environment.systemPackages = with pkgs; [
    vim
    nano
    micro
    iptables
    pcimem
    nfs-utils
    openssl
    fwupd
    iw
    psmisc
    sysstat
    hdparm
    dool # dool -cdmln 1
    parted
    ffmpeg
  ];
}
