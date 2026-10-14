# The ROCm 10.0.0 (TheRock) *runtime* the Strata engine loads, as a store path.
#
# Why a runtime outside nixpkgs at all
# ------------------------------------
# nixpkgs is frozen on ROCm 7.2.3 (`pkgs.rocmPackages.rocm-core.version` =
# 7.2.3; there is no rocmPackages_8/_9/_10 to fall back on), and ROCm 7.2.x is
# the runtime the #879 poisoned-context class reproduces on: the SAME strata
# binary and source fires 2/1399 requests on 7.2.3 and 0/1911 on ROCm 10.0.0.
# So strata.nix prepends this lib dir to the engine's LD_LIBRARY_PATH via the
# serve config's `lib_dirs`, which overrides the Nix build's RUNPATH to the
# 7.2.3 store libs. Full write-up: docs/strata-degeneration.md.
#
# What this file replaces
# -----------------------
# Until 2026-10-14 these 16 GB lived at /opt/rocm-10.0/lib, put there BY HAND
# by scripts/setup-rocm10-libs.sh (podman pull + `podman cp` + rm the scratch).
# Nothing in the system config owned that directory, a fresh host could not
# build the system without running the script first, and strata.nix needed an
# ExecStartPre `test -e` because serve/server.py's child_env() silently DROPS
# a missing lib_dirs entry and the engine would have fallen back to the buggy
# 7.2.3 without anyone noticing. All of that goes away: a store path cannot be
# missing, so the guard goes with the impurity.
#
# Two stages, deliberately
# ------------------------
#  1. `rocm10Layer` (passthru.layer) is the ONE layer blob of the pinned image
#     that carries /opt/rocm/core-10.0 (8.05 GB gzip), streamed straight out of
#     the registry and stored verbatim. It is a fixed-output derivation and its
#     hash is not a guess: an OCI layer's blob sha256 IS the digest the manifest
#     publishes, so the hash below is the value Docker Hub itself attests to.
#  2. This derivation filters `lib/` out of that blob. It is an ordinary
#     derivation, so changing the filter (e.g. to drop MIOpen and the other
#     GPUs' kernels - see "Room to trim" below) costs a re-extract, and only
#     re-fetches the 8 GB if the blob has since been garbage-collected (nothing
#     in the output references it, so `nix gc` can reclaim it).
#
# Room to trim (NOT done: this change is behaviour-neutral on purpose)
# --------------------------------------------------------------------
# The 16 GB is mostly things the engine never touches. Measured against the
# live process (26 files mapped) and the sizes on disk: MIOpen 5.2 GB (strata
# does not use MIOpen), static device archives 2.4 GB (compile-time only),
# llvm/bin + llvm/include 0.5 GB, and hipblaslt Tensile kernels for eleven
# other GPU families 2.0 GB (we map only hipblaslt/library/gfx1201, 169 MB).
# The runtime closure is ~2 GB. Trimming is one --exclude list on the tar
# below, and stage 1 makes it cheap to try - but a missing lazy dlopen fails at
# some future code path, so that wants its own change and its own soak, not a
# ride along with this one.
#
# Updating: change `imageDigest` + `layerDigest`/`layerSize` to the new image's
# values
#   skopeo inspect --raw docker://docker.io/rocm/dev-ubuntu-24.04@<digest> \
#     | jq '.layers[] | {size, digest}'
# and re-derive the LAYER digest, not the tag - `10.0.0-full` is mutable, the
# digests are not.
{
  stdenvNoCC,
  runCommand,
  curl,
  cacert,
  gnused,
  gnutar,
  gzip,
}:
let
  version = "10.0.0";
  image = "rocm/dev-ubuntu-24.04";
  # The tag this digest was also published as (documentation only - the build
  # resolves the digest and never the tag).
  tag = "10.0.0-full";
  imageDigest = "sha256:a90cf047f615abe70fbef83c64def0a2d549ef37a39c8ea545430aba4981b374";
  # The 5th of the image's 5 layers: the ROCm install itself. The other four
  # are the ubuntu base (29 MB, 7 KB, 1 KB) plus a 140 MB apt layer, none of
  # which we need - the engine dlopens nothing from the distro.
  layerDigest = "sha256:b30f0301857271613fdf668d9658e5c58cb490972158dd9d23e351c1449fe0b0";
  layerSize = 8050797785;
  # Where the runtime lives inside the layer's rootfs tar. This layer marks
  # opt/rocm opaque with a `.wh..wh..opq` whiteout and then carries exactly ONE
  # real directory, core-10.0/ (the `opt/rocm/{bin,lib,include}` names other
  # layers publish are gone, and the `etc/alternatives/rocm-lib` symlinks point
  # at /opt/rocm/core-10.0/lib) - which is why the old script had to extract
  # from THIS layer rather than follow a symlink. Inside core-10.0 the only
  # symlinks are the convenience links `amdgcn -> lib/llvm/amdgcn` and
  # `llvm -> lib/llvm`; lib/ itself is a real directory (24452 members).
  inside = "opt/rocm/core-10.0/lib";

  rocm10Layer = stdenvNoCC.mkDerivation {
    pname = "rocm10-layer";
    inherit version;

    # Fixed output => this derivation is allowed network access; everything
    # downstream of it is not.
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "sha256-sw8DAYVycWE/32aNlljlxYy0kJchWN2dI+NRwUSf4LA=";

    # 8 GB with no mirror: never try to substitute it, build it once, locally.
    preferLocalBuild = true;
    allowSubstitutes = false;

    dontUnpack = true;
    dontConfigure = true;
    dontFixup = true;

    nativeBuildInputs = [
      curl
      gnused
    ];

    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR"
      export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"

      # Docker Hub's blob endpoint wants an anonymous bearer token scoped to
      # the repository. It expires after ~5 min, which is fine: the registry
      # checks it once, then hands the blob to its CDN for the rest of the
      # transfer.
      tok=$(${curl}/bin/curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
              "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${image}:pull" \
            | ${gnused}/bin/sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
      if [ -z "$tok" ]; then
        echo "rocm10-layer: no registry token from auth.docker.io" >&2
        exit 1
      fi

      ${curl}/bin/curl -fSL --retry 8 --retry-delay 10 --retry-all-errors \
           --retry-max-time 7200 \
           -H "Authorization: Bearer $tok" \
           "https://registry-1.docker.io/v2/${image}/blobs/${layerDigest}" \
           -o "$out"

      # A truncated transfer fails the output hash anyway; checking against the
      # size the manifest publishes names the failure instead.
      size=$(stat -c%s "$out")
      if [ "$size" != "${toString layerSize}" ]; then
        echo "rocm10-layer: got $size bytes, manifest says ${toString layerSize}" >&2
        exit 1
      fi
      runHook postBuild
    '';

    passthru = {
      inherit
        image
        tag
        imageDigest
        layerDigest
        layerSize
        inside
        ;
    };
  };
in
runCommand "rocm10-runtime-${version}"
  {
    inherit version;

    # `nix eval .#...passthru.layer` -> the 8 GB blob this was extracted from,
    # for re-running the filter without hunting for the digest.
    passthru = {
      layer = rocm10Layer;
      inherit
        image
        tag
        imageDigest
        layerDigest
        inside
        ;
    };

    nativeBuildInputs = [
      gnutar
      gzip
    ];

    # tar restores the archive's own mtimes, so the tree is reproducible; the
    # umask is pinned by stdenv, so the modes are too.
  }
  ''
    mkdir -p "$out"
    # --strip-components=3: opt/rocm/core-10.0/lib/<x> -> lib/<x>.
    # ONE pattern, and it has to end in `/*`: GNU tar matches the bare
    # `opt/rocm/core-10.0/lib` unanchored, so it already swallows everything
    # under lib/, and adding the glob as a second pattern then makes tar exit 2
    # with `opt/rocm/core-10.0/lib/*: Not found in archive` (measured: bare alone
    # = 24452 members, glob alone = 24451, both = the error). tar creates lib/
    # itself as the parent of the first file, so no separate dir member needed.
    tar -xzf ${rocm10Layer} \
        --no-same-owner --no-same-permissions \
        --wildcards --strip-components=3 \
        -C "$out" \
        '${inside}/*'

    # The six SONAMEs the engine dlopens (the same list scripts/setup-rocm10-libs.sh
    # used to verify). If the layer layout ever moves, fail HERE, not at the first
    # GPU request.
    for l in \
      libamdhip64.so.7 \
      libhsa-runtime64.so.1 \
      libamd_comgr.so.3 \
      libhipblaslt.so.1 \
      libhipblas.so.3 \
      librocsolver.so.0
    do
      if [ ! -e "$out/lib/$l" ]; then
        echo "rocm10-runtime: missing lib/$l after extraction" >&2
        exit 1
      fi
    done
    [ -d "$out/lib/rocm_sysdeps/lib" ] || { echo "rocm10-runtime: missing rocm_sysdeps" >&2; exit 1; }
    [ -d "$out/lib/hipblaslt/library/gfx1201" ] || {
      echo "rocm10-runtime: missing hipblaslt gfx1201 kernels" >&2
      exit 1
    }
  ''
