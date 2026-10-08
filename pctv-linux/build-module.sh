#!/bin/sh
# Fast standalone build of pctv320cx.ko against this host's kernelPackages
# (no full system rebuild).  Leaves the result at /tmp/pctv-result.
#
# This host has max-jobs = 0 and dispatches to build machines, so the build
# normally runs on zen3/MacBook.  zen3 runs out of disk regularly ("No space
# left on device" while rustc makes a temp dir), so on failure we retry
# locally with --max-jobs (root is trusted, so the flag overrides max-jobs=0).
#
# The module is built against the FLAKE's boot.kernelPackages, which is only
# the RUNNING kernel as long as the booted generation matches the working
# tree.  After a kernel bump (7.2.3 -> 7.2.9) the two drift apart and insmod
# fails with "Invalid module format"; the version check below says so in those
# terms instead of leaving you to guess.
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

check() {
	ko=$(find /tmp/pctv-result/lib/modules -maxdepth 3 -name 'pctv320cx.ko*' 2>/dev/null | sort | head -1)
	if [ -z "$ko" ]; then
		echo "built, but no pctv320cx.ko* under /tmp/pctv-result/lib/modules" >&2
		return 1
	fi
	built=$(expr "$ko" : '.*/lib/modules/\([^/]*\)/.*')
	run=$(uname -r)
	echo "module: $ko"
	if [ "$built" != "$run" ]; then
		echo "WARNING: built for kernel $built, this system runs $run — insmod will reject it."
		echo "         boot the generation whose kernel is $built, or update the flake and"
		echo "         rebuild the system, then build the module again."
		return 1
	fi
	echo "kernel match: $built (running) — ./reload-module.sh can load it"
}

if nix build --impure --no-link -L --expr "$EXPR" --out-link /tmp/pctv-result "$@"; then
	check
	exit $?
fi

echo "== remote build failed; retrying locally (--max-jobs 4, no builders) ==" >&2
nix build --impure --no-link -L --expr "$EXPR" --out-link /tmp/pctv-result \
	--max-jobs 4 --option builders '' "$@" || exit 1
check
