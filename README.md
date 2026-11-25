# NixOS Config

Flake-based NixOS configuration for the grafton homelab. See `AGENTS.md` for the
full index and `docs/` for per-host backstory.

## Install

    git clone --depth 1 https://github.com/cjdell/nixos-config.git
    # (shallow clone; run `git fetch --unshallow` if you want the full history)

    cd nixos-config

    sudo -s

    scripts/create-partitions.sh
    scripts/mount-partitions.sh

    nixos-install --root /mnt --flake .#<hostname>

    nixos-enter --root '/mnt'

    passwd cjdell

    exit

    mv /home/nixos/nixos-config /mnt/home/cjdell/

## After install

- Provision the sops age key (see `just key-install` / `just fresh-install-key`)
  before rebuilding hosts that import `common/sops.nix`.
- On autoRollback hosts (N100-NAS, grafton-router), run `sudo nixos-confirm`
  after every `nixos-rebuild switch`/`boot` or the host rolls itself back in ~5 min.
- `--impure` is not needed; the flake evaluates in pure mode.
