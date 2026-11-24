# The strata-inkling serve layer with our monitor fixes, as an overlay on the package's share tree.
#
# WHY AN OVERLAY AND NOT A PATCH IN THE PACKAGE: the fixes are Python in serve/ (and one engine-adjacent routing
# rule), not HIP C++.  Patching the package derivation would re-run the whole C++ build for a display change; the
# engine binary is untouched, so this copies the share tree, applies the diffs in order with zero fuzz, and re-points
# bin/strata-server's PYTHONPATH at the copy.  That wrapper is the thing that actually selects the code: it
# hard-codes `PYTHONPATH=<pkg>/share/strata` and execs `python3 -m serve.server` (the unit's cwd is /, so the
# package's share would win over an override of the run config's `cwd` alone).
#
# The patches, in the order they must apply:
#   inkling-metrics.diff       per-slot/top-level prefill progress + the request table's decode rate
#   inkling-admission.diff     does_not_fit(): refuse a prompt that cannot be resident beside a busy slot
#   inkling-pick-debug.diff    the `pick:` trace (why a request took the slot it took)
#   inkling-fit-protect.diff   protect slot 0's conversation only while the new prompt FITS beside it
#   inkling-phase-label.diff   a generating request stops being labelled "reading the prompt" (a tool call's
#                              arguments are buffered, so no event ever advanced the phase)
#
# `cwd`/the tokenizer helper in ./inkling.nix follow this directory too, and `exe` keeps pointing at the package's
# untouched bin/strata-inkling.
#
# Verify a build carries them:
#   P=$(nix build .#strata-inkling-serve --no-link --print-out-paths)
#   grep -n "prompt_total" $P/share/strata/serve/server.py | head -3
#   grep PYTHONPATH $P/bin/strata-server
{
  lib,
  runCommand,
  patch,
  strataInkling,
}:

runCommand "strata-inkling-serve" { nativeBuildInputs = [ patch ]; } ''
  mkdir -p $out/share $out/bin
  cp -r ${strataInkling}/share/strata $out/share/strata
  chmod -R u+w $out/share/strata
  patch -p1 --fuzz=0 -d $out/share/strata < ${./inkling-metrics.diff}
  patch -p1 --fuzz=0 -d $out/share/strata < ${./inkling-admission.diff}
  patch -p1 --fuzz=0 -d $out/share/strata < ${./inkling-pick-debug.diff}
  patch -p1 --fuzz=0 -d $out/share/strata < ${./inkling-fit-protect.diff}
  patch -p1 --fuzz=0 -d $out/share/strata < ${./inkling-phase-label.diff}

  cp ${strataInkling}/bin/strata-server $out/bin/strata-server
  chmod u+w $out/bin/strata-server
  substituteInPlace $out/bin/strata-server \
    --replace-fail '${strataInkling}/share/strata' "$out/share/strata"
''
