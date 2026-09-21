# The forked DeepSeek Harness Web GUI on this host, served directly on
# 192.168.49.50:3080 — no proxy (see common/dsh-web-service.nix and
# docs/dsh-fork/).
#
# `trustedHosts` is the authority this service is reached by: it is what the
# /api fence admits and what the browser treats as the operator's own surface,
# so Settings works over the LAN. `settingsIp` names this machine, and its
# settings document is ~/.dsh/settings-192.168.49.50.yaml — another machine
# serving the same GUI keeps its own document.
#
# The GUI binary comes from the deepseek-harness flake input (the fork's own
# flake builds the pnpm workspace); this module only runs it.
{
  services.dshWebHarness = {
    enable = true;
    trustedHosts = [ "192.168.49.50" ];
    settingsIp = "192.168.49.50";
  };
}
