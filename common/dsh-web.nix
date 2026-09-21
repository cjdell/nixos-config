# dsh-web — start/stop/status for the DeepSeek Harness web server
# (`dsh web`), ported from the hand-placed ~/.local/bin/dsh-web so it is
# available on every host in this flake (imported from common/system.nix).
#
# `dsh-web proxy` adds network access to the otherwise loopback-only GUI:
# common/dsh-web-proxy.mjs is a tiny zero-dependency (node:net) reverse proxy
# that listens on all interfaces, forwards over loopback, and rewrites the
# Host/Origin headers to the upstream's loopback authority, because dsh
# refuses --host 0.0.0.0 and its /api fence 403s non-loopback Host/Origin.
# Deliberately not nginx and not a systemd service — opt-in per host.
#
# The bash script (./dsh-web.sh) drives `npx --yes @deepseek-ai/dsh web`, and
# both it (profile self-heal) and the proxy need `node`, so the generated
# wrapper prepends a pinned nodejs (ships node, npm, npx) to PATH before
# exec'ing. The dsh package itself is still fetched from the npm registry on
# first use and cached under ~/.npm, exactly like the original. State stays
# under $DSH_HOME (web.log, web.pid, web-proxy.log, web-proxy.pid).
{ pkgs, ... }:

let
  # bin/dsh-web (bash) and lib/dsh-web-proxy.mjs (node) in one store path so
  # the script can find the proxy next to itself.
  real = pkgs.runCommand "dsh-web" { } ''
    mkdir -p $out/bin $out/lib
    cp ${./dsh-web.sh} $out/bin/dsh-web
    cp ${./dsh-web-proxy.mjs} $out/lib/dsh-web-proxy.mjs
    chmod +x $out/bin/dsh-web
  '';
  dsh-web = pkgs.writeShellScriptBin "dsh-web" ''
    #!/usr/bin/env bash
    export PATH="${pkgs.nodejs}/bin:$PATH"
    exec "${real}/bin/dsh-web" "$@"
  '';
in
{
  environment.systemPackages = [
    dsh-web
  ];
}
