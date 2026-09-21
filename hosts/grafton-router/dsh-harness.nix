# The forked DeepSeek Harness Web GUI on this host, served directly on
# 192.168.49.1:3080 — no proxy (see common/dsh-web-service.nix and
# docs/dsh-fork/).
#
# `trustedHosts` is the authority this service is reached by: it is what the
# /api fence admits and what the browser treats as the operator's own surface,
# so Settings works over the LAN. `settingsIp` names this machine, and its
# settings document is ~/.dsh/settings-192.168.49.1.yaml — another machine
# serving the same GUI keeps its own document.
#
# The GUI binary comes from the deepseek-harness flake input (the fork's own
# flake builds the pnpm workspace); this module only runs it.
#
# To sign a browser in, run `dsh-web-url` (it prints the URL carrying the live
# startup token; `dsh-web-url --open` opens it). After that one visit the plain
# http://192.168.49.1:3080/ works — the cookie lasts `cookieMaxAgeDays`.
{
  services.dshWebHarness = {
    enable = true;
    trustedHosts = [ "192.168.49.1" ];
    settingsIp = "192.168.49.1";
  };
}
