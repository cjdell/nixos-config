#!/usr/bin/env bash
#
# Prepare the ROCm 10.0.0 (TheRock) runtime that
# hosts/zen3-nixos/ai/strata.nix pins for the Strata engine.
#
# Why this exists
# ---------------
# The Nix build of strata-0.1.43 links ROCm 7.2.3 (that is what nixpkgs has -
# even master is frozen on it). ROCm 7.2.x is what the #879 poisoned-context
# class reproduces on; ROCm 10.0.0 does not (0 fires in 1911 requests, same
# binary and source). strata.nix therefore prepends this directory to the
# engine's LD_LIBRARY_PATH via the serve config's `lib_dirs`, which overrides
# the binary's RUNPATH to the 7.2.3 store libs.
#
# The 16 GB of libs come from the pinned container image below. They are a
# local, hand-prepared asset (like the model packs), NOT built by Nix and NOT
# in the store, so they must be reproduced on a fresh host with this script
# before the strata service will start (strata.nix's ExecStartPre refuses to
# start without them).
#
# Usage:
#   ./scripts/setup-rocm10-libs.sh            # skip if already present
#   ./scripts/setup-rocm10-libs.sh --force    # re-extract
#
# Needs ~20 GB in the podman scratch root and ~16 GB free on / (the libs are
# ~16 GB; the image is pulled to /home and removed at the end).
set -euo pipefail

IMAGE="docker.io/rocm/dev-ubuntu-24.04@sha256:a90cf047f615abe70fbef83c64def0a2d549ef37a39c8ea545430aba4981b374"
DEST="/opt/rocm-10.0/lib"
PODMAN_ROOT="/home/cjdell/rocm-podman"     # scratch, removed at the end
PODMAN_RUNROOT="/run/rocm-podman"
CTR="rocm10extract"
FORCE="${1:-}"

log() { printf '[rocm10] %s\n' "$*"; }

# The pieces the Nix strata binary dlopens; libamdhip64 is the one the fix is
# really about (it is the only SONAME that changed between 7.2.3 and 10.0.0
# in our failing requests).
CHECK_LIBS=(
  libamdhip64.so.7
  libhsa-runtime64.so.1
  libamd_comgr.so.3
  libhipblaslt.so.1
  libhipblas.so.3
  librocsolver.so.0
)

verify() {
  local missing=0
  for l in "${CHECK_LIBS[@]}"; do
    if [[ -e "$DEST/$l" ]]; then
      log "  ok  $l -> $(basename "$(readlink -f "$DEST/$l")")"
    else
      log "  MISSING $l"; missing=1
    fi
  done
  [[ -d "$DEST/rocm_sysdeps/lib" ]] || { log "  MISSING rocm_sysdeps/"; missing=1; }
  return "$missing"
}

if [[ "$FORCE" != "--force" && -e "$DEST/libamdhip64.so.7" ]]; then
  log "$DEST already populated (use --force to redo). Verifying:"
  verify && { log "nothing to do."; exit 0; }
  log "incomplete - re-extracting."
fi

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"
$SUDO -v || { log "sudo is required."; exit 1; }

cleanup() {
  $SUDO podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT" rm -f "$CTR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "pulling $IMAGE (pinned digest; ~20 GB, cached if already present) ..."
$SUDO podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT" pull "$IMAGE"

log "creating extraction container ..."
$SUDO podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT" rm -f "$CTR" >/dev/null 2>&1 || true
$SUDO podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT" create --name "$CTR" "$IMAGE" true >/dev/null

TMP="$(mktemp -d /tmp/rocm10.XXXXXX)"
trap 'rm -rf "$TMP"; cleanup' EXIT

log "extracting /opt/rocm/core-10.0/lib (16 GB) ..."
$SUDO podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT" cp "$CTR:/opt/rocm/core-10.0/lib" "$TMP/lib"

log "installing to $DEST ..."
$SUDO mkdir -p "$(dirname "$DEST")"
$SUDO rm -rf "$DEST"
$SUDO mv "$TMP/lib" "$DEST"

log "verifying:"
$SUDO bash -c "$(declare -f verify); DEST='$DEST'; CHECK_LIBS=(${CHECK_LIBS[*]}); log(){ printf '[rocm10] %s\n' \"\$*\"; }; verify"

log "cleaning the podman scratch root (frees ~20 GB) ..."
$SUDO rm -rf "$PODMAN_ROOT" "$PODMAN_RUNROOT"

log "done: $(du -sh "$DEST" | cut -f1) at $DEST"
log "next: sudo nixos-rebuild switch --flake .   (strata.nix already points here)"
