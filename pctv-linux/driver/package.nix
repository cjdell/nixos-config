# The out-of-tree pctv320cx kernel module (Pinnacle PCTV 320cx analog capture).
#
# Call with the kernelPackages set of the kernel you want to run it on:
#
#   pkgs.callPackage ./pctv-linux/driver/package.nix {
#     stdenv = pkgs.linuxPackages_latest.stdenv;
#     kernel = pkgs.linuxPackages_latest.kernel;
#   }
#
# The kernel MUST be built with CONFIG_RUST=y: the driver core is Rust and the
# build generates its bindings from that kernel's headers (see Kbuild).
#
# `make` in this directory outside Nix works the same way against any prepared
# kernel build tree:
#
#   make KDIR=/lib/modules/<version>/build
{ stdenv, kernel, lib }:

stdenv.mkDerivation {
  pname = "pctv320cx";
  version = "0.1";
  src = ./.;

  # The kernel module objects are built with the kernel's own flags.
  hardeningDisable = [ "pic" ];

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = [
    "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "KVER=${kernel.modDirVersion}"
    "KBUILD_OUTPUT=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
  ];
  buildFlags = [ "modules" ];
  installFlags = [ "INSTALL_MOD_PATH=\${out}" ];

  # Fail loudly instead of producing a half-built module when the kernel has
  # no Rust support (the bindings step needs rustc + the kernel's pin-init
  # crates).
  preConfigure = ''
    if ! grep -q '^CONFIG_RUST=y' ${kernel.dev}/lib/modules/${kernel.modDirVersion}/include/config/kernel.release 2>/dev/null \
       && [ ! -e ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build/rust ]; then
      echo "pctv320cx needs a kernel built with CONFIG_RUST=y (rust/ missing in the build tree)"
      exit 1
    fi
  '';

  meta = {
    description = "V4L2 driver for the Pinnacle PCTV 320cx (composite / S-Video)";
    longDescription = ''
      Rust + C kernel module for the analog side of the Pinnacle PCTV 320cx
      ExpressCard: DiB0700 USB bridge (firmware download, I2C tunnel),
      Conexant CX25843 decoder, BT.656 to UYVY capture over videobuf2.
      See FINDINGS.md in this directory for the hardware reverse-engineering.
    '';
    homepage = "https://github.com/cjdell/nixos-config/tree/master/pctv-linux";
    license = lib.licenses.gpl2;
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}
