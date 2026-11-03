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
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ../../common/folding-at-home-native.nix ];

  services.folding-at-home-native = {
    enable = true;
    userName = "cjdell";
    teamNumber = 236565;
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
    httpAddresses = [ "0.0.0.0:7396" ];
    allowAddresses = [
      "127.0.0.1" # loopback — fah-provision/fahctl connect here
      "::1"
      "192.168.49.0/24" # LAN
      "10.47.0.0/16" # WireGuard
      "100.64.0.0/10" # tailnets
    ];

    # NOT linked to the FAH account: the token lives in secrets/fah.yaml,
    # which only sops-enabled hosts can read, and this machine has never had
    # the fleet age key at /var/lib/sops-nix/key.txt. Folding works without
    # it — the points just do not show up under the account on
    # app.foldingathome.org. To link it: import sops-nix + common/sops.nix
    # (see hosts/asus-i7-6700-nixos/folding-heater.nix), install the shared
    # key, and set accountTokenFile = config.sops.secrets.fah_account_token.path.
  };

  # The native module exists for AMD GPUs, so it wires up the ROCm OpenCL ICD.
  # Here the GPU is the RTX 2060: point OCL_ICD_VENDORS at the NVIDIA driver's
  # own ICD and give the FAH core the driver's libraries (same override as
  # hosts/asus-i7-6700-nixos/folding-heater.nix, and the reason
  # hardware.nvidia.package — with its patchelf workaround, which the driver's
  # bin/ and OpenCL bits come from — is what these paths resolve through).
  systemd.services.fah-client.environment = lib.mkIf config.services.folding-at-home-native.enable {
    OCL_ICD_VENDORS = lib.mkForce "${config.hardware.nvidia.package}/etc/OpenCL/vendors";
    LD_LIBRARY_PATH = lib.mkForce (
      lib.makeLibraryPath [
        pkgs.ocl-icd
        pkgs.expat
        pkgs.zlib
        config.hardware.nvidia.package
      ]
    );
    # The fah user is an isSystemUser with HOME=/var/empty, and the NVIDIA
    # userspace caches JIT'd kernels under $HOME/.nv — keep them in the
    # service's CacheDirectory so they survive (and speed up) restarts.
    HOME = "/var/cache/fah-client";
  };

  systemd.services.fah-client.serviceConfig.CacheDirectory = "fah-client";

  # The container kept its state in /srv/fah (fah user, uid 7396). That tree
  # is now orphaned — the native client's state is the SQLite DB in
  # /var/lib/fah-client. Nothing reads /srv/fah any more; it is left in place
  # rather than deleted so the container's work-unit history can still be
  # inspected if a folding result ever looks missing.
}
