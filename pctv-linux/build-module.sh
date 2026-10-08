#!/bin/sh
# Fast standalone build of pctv320cx.ko against this host's kernelPackages
# (no full system rebuild).  Leaves the result at /tmp/pctv-result.
#
# This host has max-jobs = 0 and dispatches to build machines, so the build
# normally runs on zen3/MacBook.  zen3 runs out of disk regularly ("No space
# left on device" while rustc makes a temp dir), so on failure we retry
# locally with --max-jobs (root is trusted, so the flag overrides max-jobs=0).
set -u
cd "$(dirname "$0")/.." || exit 1

EXPR='
let
  f = builtins.getFlake "/home/cjdell/nixos-config";
  kp = f.nixosConfigurations.macbook-pro-2009-nixos.config.boot.kernelPackages;
in
import ./pctv-linux/driver/package.nix {
  stdenv = kp.stdenv;
  kernel = kp.kernel;
  lib = import <nixpkgs/lib>;
}
'

if nix build --impure --no-link -L --expr "$EXPR" --out-link /tmp/pctv-result "$@"; then
	exit 0
fi

echo "== remote build failed; retrying locally (--max-jobs 4, no builders) ==" >&2
exec nix build --impure --no-link -L --expr "$EXPR" --out-link /tmp/pctv-result \
	--max-jobs 4 --option builders '' "$@"
