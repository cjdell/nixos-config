# The strata-inkling serve layer with our monitor fixes, as an overlay on the package's share tree.
#
# WHY AN OVERLAY AND NOT A PATCH IN THE PACKAGE: the two fixes (per-slot/top-level prefill progress and the request
# table's decode rate - see inkling-metrics.diff) are Python in serve/server.py. Patching the package derivation would
# re-run the whole HIP C++ build for a display change; the engine binary is untouched, so this copies the share tree,
# applies the diff with zero fuzz, and re-points bin/strata-server's PYTHONPATH at the copy.  That wrapper is the thing
# that actually selects the code: it hard-codes `PYTHONPATH=<pkg>/share/strata` and execs `python3 -m serve.server`
# (the unit's cwd is /, so the package's share would win over an override of the run config's `cwd` alone).
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

  cp ${strataInkling}/bin/strata-server $out/bin/strata-server
  chmod u+w $out/bin/strata-server
  substituteInPlace $out/bin/strata-server \
    --replace-fail '${strataInkling}/share/strata' "$out/share/strata"
''
