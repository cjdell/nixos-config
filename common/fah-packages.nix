# Packages for the native Folding@home v8 service
# (common/folding-at-home-native.nix).
#
# Neither piece is in nixpkgs any more:
#
# * The `foldingathome` package was removed (v7 is EOL; v8 "Bastet" is only
#   distributed as a tarball/deb/rpm from download.foldingathome.org). The
#   tarball is a debian-10 glibc build: `fah-client` needs an interpreter and
#   RUNPATH (autoPatchelf) and dlopens `libOpenCL.so.1` at runtime (cbang
#   `OpenCLLibrary.cpp`), which the service provides via LD_LIBRARY_PATH.
#
# * AMD killed the ROCm OpenCL runtime, so nixpkgs has no `rocm-opencl-icd`
#   either. The last ROCm release that ships it is 6.4.3, and FAH v8 + AMD
#   GPU on Linux is documented against exactly that version (the "Ultimate
#   AMD GPU Linux FAH Guide" on the FAH forum; it works on every AMD GPU,
#   including this Navi 10 / gfx1010 box). So the ICD is reassembled here
#   from AMD's own apt repository: rocm-opencl (the OpenCL driver) with its
#   runtime closure — hsa-rocr (KFD runtime), comgr (kernel compiler, LLVM
#   bundled), rocprofiler-register (NEEDED by hsa), rocm-core, and
#   rocm-device-libs (the amdgcn bitcode comgr compiles kernels with).
#
# Tested end-to-end on zen1-nixos (RX 5700 XT): clinfo/fah-client enumerate
# `gfx1010:xnack-` as an OpenCL 2.0 device, driver 3649.0 (HSA1.1,LC).
pkgs:
let
  inherit (pkgs)
    lib
    stdenv
    stdenvNoCC
    fetchurl
    autoPatchelfHook
    dpkg
    ;

  # The deb (not the tarball) because it also ships `fahctl`, the official
  # command-line control script — a fresh v8 client starts PAUSED (the
  # group.json default), and `fahctl fold` is the supported headless way to
  # start folding without ever opening Web Control.
  fah-client = stdenv.mkDerivation (finalAttrs: {
    pname = "fah-client";
    version = "8.5.6";

    src = fetchurl {
      url = "https://download.foldingathome.org/releases/public/fah-client/debian-10-64bit/release/fah-client_${finalAttrs.version}_amd64.deb";
      hash = "sha256-ZD3gQDOhy5cqgeOhk9cQ6Rmk80Y0qYfxGtxM7mH9rv4=";
    };

    dontConfigure = true;
    dontBuild = true;

    nativeBuildInputs = [
      dpkg
      autoPatchelfHook
    ];

    # buildInputs (not runtimeDependencies): this nixpkgs' auto-patchelf only
    # *searches* the --libs dirs it gathers from buildInputs; runtime deps
    # would merely extend the executable's RUNPATH.
    buildInputs = with pkgs; [
      systemd
      lz4
      zlib
      openssl
      stdenv.cc.cc.lib
    ];

    python = pkgs.python3.withPackages (ps: [ ps.websocket-client ]);

    unpackPhase = ''
      runHook preUnpack
      dpkg-deb -x $src deb-root
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -m755 deb-root/usr/bin/fah-client $out/bin/fah-client
      sed "1s|.*|#!${finalAttrs.python}/bin/python3 -E|" deb-root/usr/bin/fahctl >$out/bin/fahctl
      chmod 755 $out/bin/fahctl
      runHook postInstall
    '';
  });

  rocmVersion = "6.4.3";
  rocmPool = "https://repo.radeon.com/rocm/apt/${rocmVersion}/pool/main";

  rocmDebs = [
    {
      url = "${rocmPool}/r/rocm-opencl/rocm-opencl_2.0.0.60403-128~24.04_amd64.deb";
      hash = "sha256-nWNYHcqEKBipyCi0MToUjDdsYyZg9WBktb3NAn8AhxA=";
    }
    {
      url = "${rocmPool}/h/hsa-rocr/hsa-rocr_1.15.0.60403-128~24.04_amd64.deb";
      hash = "sha256-EgSaEgn4EScgm4J6kFciwDz6gxswoTKyp5tEPmmXnbo=";
    }
    {
      url = "${rocmPool}/c/comgr/comgr_3.0.0.60403-128~24.04_amd64.deb";
      hash = "sha256-6i48A60gY0LNwzR2SfyM+m6IbtZmWJGRjq1UY/O0+uI=";
    }
    {
      url = "${rocmPool}/r/rocprofiler-register/rocprofiler-register_0.4.0.60403-128~24.04_amd64.deb";
      hash = "sha256-xkgCcKw4G0CDuIjn73pCey5yQz2dz6Xwb52UdBU9p38=";
    }
    {
      url = "${rocmPool}/r/rocm-core/rocm-core_6.4.3.60403-128~24.04_amd64.deb";
      hash = "sha256-imJZeeN0tohcM1tgeKVtnzPEUa1+FQhJCgaqQqUzxv4=";
    }
    {
      url = "${rocmPool}/r/rocm-device-libs/rocm-device-libs_1.0.0.60403-128~24.04_amd64.deb";
      hash = "sha256-2HJSBOygw+CiM1J4TmyTEU6YC4e+nB9xx8+cG1ISHtw=";
    }
  ];

  rocm-opencl = stdenvNoCC.mkDerivation {
    pname = "rocm-opencl";
    version = rocmVersion;

    srcs = map (d: fetchurl d) rocmDebs;

    nativeBuildInputs = [
      dpkg
      autoPatchelfHook
    ];

    # See the fah-client note: the search path comes from buildInputs.
    buildInputs = with pkgs; [
      libdrm # libdrm.so.2 + libdrm_amdgpu.so.1
      elfutils # libelf.so.1 — NOT pkgs.libelf, that is the old ELF library
      numactl
      zlib
      zstd
      stdenv.cc.cc.lib
    ];

    unpackPhase = ''
      runHook preUnpack
      mkdir -p deb-root
      for deb in $srcs; do
        dpkg-deb -x "$deb" deb-root
      done
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -aR deb-root/opt/rocm-${rocmVersion}/. $out/

      # The deb's clinfo needs the distro's libOpenCL; the ICD is all we want.
      rm -f $out/bin/clinfo
      rmdir $out/bin 2>/dev/null || true

      # An ocl-icd vendor file pointing at this store path's ICD, consumed
      # through OCL_ICD_VENDORS by the service.
      mkdir -p $out/etc/OpenCL/vendors
      echo "$out/lib/libamdocl64.so" >$out/etc/OpenCL/vendors/amdocl64.icd

      runHook postInstall
    '';
  };
  # Headless provisioning: a fresh v8 client starts paused with every GPU
  # disabled (group.json defaults; the intended UX is pressing buttons in Web
  # Control). This talks to the client's websocket API the same way
  # `fahctl`/app.foldingathome.org do: enable every supported GPU in the
  # default resource group and start folding.
  fah-provision =
    let
      python = pkgs.python3.withPackages (ps: [ ps.websocket-client ]);
    in
    pkgs.writeScriptBin "fah-provision" ''
      exec ${python}/bin/python3 -E ${./fah-provision.py} "$@"
    '';
in
{
  inherit fah-client rocm-opencl fah-provision;
}
