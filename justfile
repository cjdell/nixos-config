# NixOS rebuild + sops secret management for this flake.
#
# Run recipes from the repo root. `just` is in systemPackages
# (common/system.nix) once the host has been rebuilt; until then invoke it via:
#     nix shell nixpkgs#just --command just <recipe>
#
# The sops age key is derived from an ssh ed25519 private key (see .sops.yaml):
#   - default ssh key:   ~/.ssh/id_ed25519_ps   (passphrase-protected)
#   - key location:      /var/lib/sops-nix/key.txt   (common/sops.nix)
#   - ssh-to-age is not on PATH, so recipes use `nix run nixpkgs#ssh-to-age`
#
# If the ssh key is passphrase-protected, either export SSH_TO_AGE_PASSPHRASE
# in your shell or pass it per-invocation:
#     just key-install --set passphrase 'hunter2'

set shell := ["bash", "-euo", "pipefail", "-c"]

# --- settings ---------------------------------------------------------------

# ssh private key the sops age key is derived from (see .sops.yaml)
ssh_key := "~/.ssh/id_ed25519_ps"

# passphrase for that key when it is passphrase-protected
passphrase := env_var_or_default("SSH_TO_AGE_PASSPHRASE", "")

# where sops-nix expects the age key on every host (common/sops.nix)
age_key_path := "/var/lib/sops-nix/key.txt"

# local copy of the derived age key (handy for sops editing on this machine)
age_key_file := "~/age-key.txt"

# sops-managed secrets file
secrets := "secrets/secrets.yaml"

# ssh user for remote hosts
user := "cjdell"

# hosts that import common/sops.nix (targets for `key-install-all`)
sops_hosts := "N100-NAS N40L-NAS GEN8-NAS alderlake-thinkpad"

# current hostname (used to pick local vs remote install)
hostname := `hostname`

# ssh-to-age is not on PATH; run it from nixpkgs
ssh_to_age := "nix run nixpkgs#ssh-to-age --"

# Show all available recipes (default when `just` is run with no arguments).
# Placed first so that a bare `just` lists the recipes instead of running one.
default:
    @just --list --justfile {{ justfile() }}

# --- rebuilding --------------------------------------------------------------

# Switch the current host (canonical rebuild)
rebuild:
    sudo nixos-rebuild switch --impure --flake . --max-jobs 1

# Build the current host into the boot generation (reboot to activate)
reboot:
    sudo nixos-rebuild boot --impure --flake . --max-jobs 1

# Rebuild any host:  just rebuild-host N100-NAS
rebuild-host host:
    sudo nixos-rebuild switch --impure --flake .#{{ host }} --max-jobs 1

# Boot-build any host:  just reboot-host N100-NAS
reboot-host host:
    sudo nixos-rebuild boot --impure --flake .#{{ host }} --max-jobs 1

# Confirm the current generation. MANDATORY after every rebuild on autoRollback
# hosts (currently N100-NAS and zen3-nixos), or the machine rolls itself back
# and reboots within ~5 minutes.
confirm:
    sudo nixos-confirm

# rebuild + confirm in one go (only use on autoRollback hosts)
up:
    just rebuild
    just confirm

# Format all .nix files (nixfmt)
format:
    ./format.sh

# --- managing secrets --------------------------------------------------------
# The recipes below use `sops`, which is installed on sops hosts via
# common/sops.nix (`environment.systemPackages`).

# Edit the secrets file. Needs an age key locally (SOPS_AGE_KEY_FILE or
# ~/.config/sops/age/keys.txt; sops hosts get it from common/sops.nix).
edit file=secrets:
    @key="${SOPS_AGE_KEY_FILE:-}"; \
    if [ -n "$key" ] && [ ! -r "$key" ]; then \
        echo "error: sops key $key is not readable by you (sops-nix keeps it root-only)." >&2; \
        echo "  fix:    just key-generate  then  export SOPS_AGE_KEY_FILE=~/age-key.txt" >&2; \
        echo "  (avoid 'sudo just edit' - sops would rewrite the file as root)" >&2; \
        exit 1; \
    fi
    sops {{ file }}

# Print all decrypted secrets (sensitive!)
decrypt file=secrets:
    @key="${SOPS_AGE_KEY_FILE:-}"; \
    if [ -n "$key" ] && [ ! -r "$key" ]; then \
        echo "error: sops key $key is not readable by you (sops-nix keeps it root-only)." >&2; \
        echo "  fix:    just key-generate  then  export SOPS_AGE_KEY_FILE=~/age-key.txt" >&2; \
        echo "  or:     sudo just decrypt   (read-only, safe)" >&2; \
        exit 1; \
    fi
    sops -d {{ file }}

# Print one secret:  just show immich_db_password
show key file=secrets:
    @key="${SOPS_AGE_KEY_FILE:-}"; \
    if [ -n "$key" ] && [ ! -r "$key" ]; then \
        echo "error: sops key $key is not readable by you (sops-nix keeps it root-only)." >&2; \
        echo "  fix:    just key-generate  then  export SOPS_AGE_KEY_FILE=~/age-key.txt" >&2; \
        echo "  or:     sudo just show {{ key }}   (read-only, safe)" >&2; \
        exit 1; \
    fi
    sops -d --extract '["{{ key }}"]' {{ file }}

# Re-encrypt secrets for every recipient currently listed in .sops.yaml.
# Run after adding a key to .sops.yaml (and again after removing an old one)
# to add/drop that recipient from the encrypted file.
key-update file=secrets:
    @key="${SOPS_AGE_KEY_FILE:-}"; \
    if [ -n "$key" ] && [ ! -r "$key" ]; then \
        echo "error: sops key $key is not readable by you (sops-nix keeps it root-only)." >&2; \
        echo "  fix:    just key-generate  then  export SOPS_AGE_KEY_FILE=~/age-key.txt" >&2; \
        echo "  (avoid 'sudo just key-update' - sops would rewrite the file as root)" >&2; \
        exit 1; \
    fi
    sops updatekeys {{ file }}

# --- deriving / installing the age key --------------------------------------

# Print the age public key derived from {{ssh_key}} (should match .sops.yaml
# unless you are rotating to a new key)
key-pub:
    @{{ ssh_to_age }} < {{ ssh_key }}.pub

# Derive the age private key and save it to a file (default ~/age-key.txt),
# e.g. for sops editing or copying onto a fresh machine
key-generate out=age_key_file:
    @if [ -n "{{ passphrase }}" ]; then export SSH_TO_AGE_PASSPHRASE='{{ passphrase }}'; fi
    @{{ ssh_to_age }} -private-key -i {{ ssh_key }} > {{ out }} || { rm -f {{ out }}; exit 1; }
    @chmod 600 {{ out }}
    @echo "wrote age key to {{ out }}"

# Install the derived age key on THIS machine (fresh install after first boot,
# or rotation). Refuses to install unless the derived pubkey is listed in
# .sops.yaml (check with `just key-pub`).
key-install:
    @derived="$({{ ssh_to_age }} < {{ ssh_key }}.pub)"; \
    grep -qF "$derived" .sops.yaml || { \
        echo "error: pubkey $derived is not in .sops.yaml; add it there first (or check ssh_key={{ ssh_key }})" >&2; \
        exit 1; \
    }
    @if [ -n "{{ passphrase }}" ]; then export SSH_TO_AGE_PASSPHRASE='{{ passphrase }}'; fi
    sudo mkdir -p {{ age_key_path }}
    {{ ssh_to_age }} -private-key -i {{ ssh_key }} | sudo tee {{ age_key_path }} > /dev/null
    sudo chmod 400 {{ age_key_path }}
    @echo "installed age key at {{ age_key_path }}"

# Install the derived age key on a remote host over ssh (rotation).
# Requires ssh access as {{user}} and passwordless sudo on the target.
key-install-remote host:
    @derived="$({{ ssh_to_age }} < {{ ssh_key }}.pub)"; \
    grep -qF "$derived" .sops.yaml || { \
        echo "error: pubkey $derived is not in .sops.yaml; add it there first (or check ssh_key={{ ssh_key }})" >&2; \
        exit 1; \
    }
    @if [ -n "{{ passphrase }}" ]; then export SSH_TO_AGE_PASSPHRASE='{{ passphrase }}'; fi
    ssh {{ user }}@{{ host }} "sudo mkdir -p {{ age_key_path }}"
    {{ ssh_to_age }} -private-key -i {{ ssh_key }} | ssh {{ user }}@{{ host }} "sudo tee {{ age_key_path }} > /dev/null && sudo chmod 400 {{ age_key_path }}"
    @echo "installed age key on {{ host }}"

# Install the derived age key on every sops host (the current host is done
# locally, the rest over ssh). Fails fast on the first unreachable host.
key-install-all:
    @for h in {{ sops_hosts }}; do \
        echo "==> installing age key on $h"; \
        if [ "$h" = "{{ hostname }}" ]; then \
            SSH_TO_AGE_PASSPHRASE='{{ passphrase }}' just key-install; \
        else \
            SSH_TO_AGE_PASSPHRASE='{{ passphrase }}' just key-install-remote "$h"; \
        fi; \
    done

# Provision the age key into a freshly mounted target root BEFORE running
# nixos-install (i.e. after scripts/mount-partitions.sh). Run as root, and
# pass the ssh key path explicitly since root's ~ is /root:
# sudo just fresh-install-key /mnt --set ssh_key /home/cjdell/.ssh/id_ed25519_ps
fresh-install-key mount="/mnt":
    @derived="$({{ ssh_to_age }} < {{ ssh_key }}.pub)"; \
    grep -qF "$derived" .sops.yaml || { \
        echo "error: pubkey $derived is not in .sops.yaml; add it there first (or check ssh_key={{ ssh_key }})" >&2; \
        exit 1; \
    }
    @if [ -n "{{ passphrase }}" ]; then export SSH_TO_AGE_PASSPHRASE='{{ passphrase }}'; fi
    mkdir -p {{ mount }}/var/lib/sops-nix
    {{ ssh_to_age }} -private-key -i {{ ssh_key }} | tee {{ mount }}/var/lib/sops-nix/key.txt > /dev/null
    chmod 400 {{ mount }}/var/lib/sops-nix/key.txt
    @echo "provisioned age key at {{ mount }}/var/lib/sops-nix/key.txt"

# --- key rotation ------------------------------------------------------------
#
# 1. Generate a new ssh key, then add its derived age pubkey to .sops.yaml
#    (keep the old key listed for now):
#        just key-pub --set ssh_key ~/.ssh/<new-key>
# 2. Re-encrypt the secrets for all listed keys:
#        just key-update
# 3. (Optional) Remove the old key from .sops.yaml and run `just key-update`
#    again so it is dropped from the encrypted file.
# 4. Provision the new key file on every host:
# just key-install-all
key-rotate:
    @echo "following the documented order above (update keys, then install everywhere):"
    just key-update
    just key-install-all
