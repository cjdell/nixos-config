{ config, ... }:

# The FAH account token as a sops secret — split out of
# common/folding-at-home.nix so that hosts running folding-at-home *without*
# sops (the legacy `machines/` configs) still evaluate. Import this alongside
# `(import ./folding-at-home.nix) <dgpu>` on hosts that do import sops-nix and
# common/sops.nix.
#
# The token lives in secrets/fah.yaml (encrypted to the key in .sops.yaml)
# instead of `builtins.readFile` of an absolute path. That read made every host
# importing the module need `--impure` — `secrets/` is outside the flake
# source, so a pure build refused it — and it baked the token into the
# world-readable store as part of the container's environment.
#
# The container receives it through an env file rather than `environment = {}`:
# a sops secret only exists after activation (too late for the container's
# environment to be built from it), and its path must stay outside the store.
{
  sops.secrets."fah_account_token" = {
    sopsFile = ../secrets/fah.yaml;
    # A rotated token only reaches the running container once it is recreated.
    restartUnits = [ "podman-fah.service" ];
  };

  sops.templates."fah-env" = {
    owner = "root";
    mode = "0400";
    content = ''
      ACCOUNT_TOKEN=${config.sops.placeholder.fah_account_token}
    '';
  };

  virtualisation.oci-containers.containers.fah.environmentFiles = [
    config.sops.templates."fah-env".path
  ];

  # Containers start at `multi-user.target` and `sops-install-secrets.service`
  # runs during sysinit, so the order is already right in practice; stating it
  # keeps a container from starting (and failing) without its env file.
  systemd.services.podman-fah = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };
}
