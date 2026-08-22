{
  lib,
  stdenv,
  squashfsTools,
  closureInfo,

  # The root directory of the squashfs filesystem is filled with the
  # closures of the Nix store paths listed here.
  storeContents ? [ ],
}:

stdenv.mkDerivation {
  name = "nix-store";
  __structuredAttrs = true;

  # the image will be self-contained so we can drop references
  # to the closure that was used to build it
  unsafeDiscardReferences.out = true;

  buildCommand = ''
    closureInfo=${closureInfo { rootPaths = storeContents; }}

    # Also include a manifest of the closures in a format suitable
    # for nix-store --load-db.
    cp $closureInfo/registration nix-path-registration
  ''
  + ''
    # Generate the tarball image.
    mkdir -p $out/nix-store
    cp -av $(cat $closureInfo/store-paths) $out/nix-store/
    cp -av nix-path-registration $out/nix-store/
  '';
}
