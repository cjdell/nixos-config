# kabylakeitx-nixos — Folding@home.
#
# This box used to fold in the linuxserver/foldingathome *container*
# (common/folding-at-home.nix "nvidia"). That arrangement is now the fleet's
# odd one out: the image on disk was 14 months old, and a container only ever
# updates when somebody remembers to re-pull it, so the client inside it drifts
# indefinitely. It now runs the native v8 ("Bastet") client — the same
# common/folding-at-home-native.nix that hosts/zen1-nixos,
# hosts/haswellatx-nixos and hosts/asus-i7-6700-nixos fold on.
#
# Progress: `journalctl -u fah-client -f`, the Web Control on :7396, or
# `tail /var/lib/fah-client/log.txt`. Paused/resumed by stopping the unit:
#   sudo systemctl stop  fah-client   # idle the box (e.g. while a render runs)
#   sudo systemctl start fah-client   # fold again (un-paused, see the module)
{ lib, ... }:

{
  imports = [
    ../../common/folding-heater.nix
    ../../common/fah-nvidia.nix
  ];

  services.folding-at-home-native = {
    # While this box is on video duty it folds GPU-only: the lossless x264
    # render owns the 8 Kaby Lake threads, so 0 CPU slots (the client's GPU
    # slot still runs). The client honours <cpus>0</cpus> (no CPU slots are
    # created; verified live over the WS API). Caveat from hosts/asus-i7-6700:
    # the client's SQLite DB (/var/lib/fah-client/client.db, `db.sql` on
    # older clients) persists settings and config.xml only seeds — flipping
    # this option needs the DB wiped once (plus work/ for the assignments),
    # as done at deploy. Drop to null (= client default 75 %) to fold as a
    # full heater again.
    cpus = 0;
    # gpuUsage left at the module default (100).
  };

  # This box is a video workbench, not a pure heater: no fah-panel and no
  # sleep-disable (the shared folding-heater.nix enables both by default).
  services.fah-panel.enable = false;
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "yes";
    AllowHibernation = "yes";
    AllowHybridSleep = "yes";
    AllowSuspendThenHibernate = "yes";
  };

  # The native module exists for AMD GPUs, so it wires up the ROCm OpenCL ICD.
  # Here the GPU is the RTX 2060: point OCL_ICD_VENDORS at the NVIDIA driver's
  # own ICD and give the FAH core the driver's libraries (same override as
  # hosts/asus-i7-6700-nixos/folding-heater.nix, and the reason
  # hardware.nvidia.package — with its patchelf workaround, which the driver's
  # bin/ and OpenCL bits come from — is what these paths resolve through).
  # (The shared fah-nvidia.nix module does this wiring; this file only adds
  # the host-specific cpus=0.)

  # The container kept its state in /srv/fah (fah user, uid 7396). That tree
  # is now orphaned — the native client's state is the SQLite DB in
  # /var/lib/fah-client. Nothing reads /srv/fah any more; it is left in place
  # rather than deleted so the container's work-unit history can still be
  # inspected if a folding result ever looks missing.
}
