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

# directory where sops-nix expects the age key on every host (common/sops.nix)
age_key_dir := "/var/lib/sops-nix"

# the age key file itself
age_key_path := age_key_dir + "/key.txt"

# local copy of the derived age key (handy for sops editing on this machine)
age_key_file := "~/age-key.txt"

# sops-managed secrets file
secrets := "secrets/secrets.yaml"

# ssh user for remote hosts
user := "cjdell"

# hosts that import common/sops.nix (targets for `key-install-all`)
sops_hosts := "N100-NAS N40L-NAS GEN8-NAS alderlake-thinkpad"

# hosts to target with `deploy-all` (current fleet under hosts/; add any
# legacy machines/ hosts here if you want them included)
deploy_hosts := "GEN8-NAS N100-NAS N40L-NAS alderlake-thinkpad rocketlakelatitude zen3-nixos"

# where the repo lives on each host
repo := "~/nixos-config"

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

# On autoRollback hosts (N100-NAS, zen3-nixos) the machine rolls itself back
# and reboots within ~5 minutes unless the new generation is confirmed.
# Confirm the current generation after every rebuild.
confirm:
    sudo nixos-confirm

# rebuild + confirm in one go (only use on autoRollback hosts)
up:
    just rebuild
    just confirm

# Generic fleet runner: checks ssh reachability (offline vs no-key-auth), git
# state (clean/DIRTY + short SHA, (current) = same as this machine's HEAD) and
# github auth via the forwarded ssh agent (machines hold no keys of their own),
# shows a menu to pick hosts, then runs an op on each selection (locally here,
# ssh -t -A elsewhere). ops: deploy = git pull + nixos-rebuild switch (+ nixos-
# confirm on autoRollback hosts); reboot = sudo reboot.
# Select hosts and run an op (deploy|reboot) on them.
hosts-run op="deploy":
    @tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; \
    : > "$tmp/reachable"; : > "$tmp/unreachable"; : > "$tmp/noauth"; : > "$tmp/info"; : > "$tmp/selected"; : > "$tmp/failed"; \
    echo "==> checking ssh reachability of: {{ deploy_hosts }}"; \
    for h in {{ deploy_hosts }}; do \
        if [ "$h" = "{{ hostname }}" ]; then \
            echo "$h" >> "$tmp/reachable"; \
        else \
            out="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new {{ user }}@"$h" true 2>&1 || true)"; \
            if [ -z "$out" ]; then \
                echo "$h" >> "$tmp/reachable"; \
            elif echo "$out" | grep -q "Permission denied"; then \
                echo "$h" >> "$tmp/noauth"; \
            else \
                echo "$h" >> "$tmp/unreachable"; \
            fi; \
        fi; \
    done; \
    if [ ! -s "$tmp/reachable" ]; then \
        echo "error: no reachable hosts"; exit 1; \
    fi; \
    echo "==> collecting git state from reachable hosts"; \
    local_sha="$(git -C {{ repo }} rev-parse --short HEAD 2>/dev/null)"; \
    for h in $(cat "$tmp/reachable"); do \
        if [ "$h" = "{{ hostname }}" ]; then \
            sha_now="$(git -C {{ repo }} rev-parse --short HEAD 2>/dev/null)"; \
            if git -C {{ repo }} status --porcelain 2>/dev/null | grep -qv '^??'; then dirty_now=1; else dirty_now=0; fi; \
            auth_out="$(ssh -n -T -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)"; \
            case "$auth_out" in *"successfully authenticated"*) auth_now=1;; *) auth_now=0;; esac; \
        else \
            st="$(ssh -n -A -o BatchMode=yes -o ConnectTimeout=5 {{ user }}@"$h" 'sha=$(git -C {{ repo }} rev-parse --short HEAD 2>/dev/null); dirty=0; if git -C {{ repo }} status --porcelain 2>/dev/null | grep -qv "^??"; then dirty=1; fi; auth=0; auth_out=$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true); case "$auth_out" in *"successfully authenticated"*) auth=1;; esac; echo "$sha $dirty $auth"' 2>/dev/null || true)"; \
            sha_now="${st%% *}"; rest="${st#* }"; dirty_now="${rest%% *}"; auth_now="${rest##* }"; [ -n "$dirty_now" ] || dirty_now=0; [ -n "$auth_now" ] || auth_now=0; \
        fi; \
        echo "$h|$sha_now|$dirty_now|$auth_now" >> "$tmp/info"; \
    done; \
    echo; \
    echo "Available hosts ((current) = same SHA as this machine; no-github = pull will fail):"; \
    i=0; \
    while IFS='|' read -r h sha d a; do \
        i=$((i+1)); \
        status="clean"; [ "$d" = "1" ] && status="DIRTY"; \
        cur=""; [ -n "$local_sha" ] && [ -n "$sha" ] && [ "$sha" = "$local_sha" ] && cur=" (current)"; \
        gauth=""; [ "$a" != "1" ] && gauth=" (no-github)"; \
        sha_disp="$sha"; [ -z "$sha_disp" ] && sha_disp="-"; \
        printf '  [%d] %-20s %-6s %s%s%s\n' "$i" "$h" "$status" "$sha_disp" "$cur" "$gauth"; \
    done < "$tmp/info"; \
    if awk -F'|' '$4 != 1 {n++} END {exit !n}' "$tmp/info"; then \
        echo "WARNING: github auth failed for: $(awk -F'|' '$4 != 1 {printf "%s ", $1}' "$tmp/info")(agent not forwarded?)"; \
    fi; \
    if [ -s "$tmp/noauth" ]; then \
        echo "  reachable, but key auth failed (ssh in once with a password to fix): $(tr '\n' ' ' < "$tmp/noauth")"; \
    fi; \
    echo "  offline (skipped): $(tr '\n' ' ' < "$tmp/unreachable")"; \
    read -r -p "Select hosts for '{{ op }}' (space-separated numbers, 'a' = all, Enter = none): " sel; \
    if [ -z "$sel" ]; then echo "no hosts selected; aborted"; exit 0; fi; \
    if [ "$sel" = "a" ] || [ "$sel" = "A" ]; then \
        cut -d'|' -f1 "$tmp/info" > "$tmp/selected"; \
    else \
        for n in $sel; do \
            case "$n" in *[!0-9]*) echo "invalid selection: $n"; exit 0;; esac; \
            line="$(sed -n "${n}p" "$tmp/info")"; \
            if [ -z "$line" ]; then echo "invalid selection: $n (out of range)"; exit 0; fi; \
            echo "${line%%|*}" >> "$tmp/selected"; \
        done; \
        sort -u "$tmp/selected" -o "$tmp/selected"; \
    fi; \
    echo "will run '{{ op }}' on: $(tr '\n' ' ' < "$tmp/selected")"; \
    case "{{ op }}" in \
        deploy) cmd="git pull && GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' sudo nixos-rebuild switch --impure --flake . --max-jobs 1 && { if command -v nixos-confirm >/dev/null 2>&1; then sudo nixos-confirm; fi; }";; \
        reboot) cmd="sudo reboot";; \
        *) echo "unknown op: {{ op }} (supported: deploy, reboot)"; exit 1;; \
    esac; \
    read -r -p "Proceed? [y/N] " ans; \
    case "$ans" in y|Y) ;; *) echo "aborted"; exit 0;; esac; \
    for h in $(cat "$tmp/selected"); do \
        echo; \
        echo "==> {{ op }} on $h"; \
        if [ "$h" = "{{ hostname }}" ]; then \
            if ( cd {{ repo }} && eval "$cmd" ); then \
                echo "$h: ok"; \
            else \
                echo "$h: FAILED"; echo "$h" >> "$tmp/failed"; \
            fi; \
        else \
            if ssh -t -A {{ user }}@"$h" "cd {{ repo }} && $cmd"; then \
                echo "$h: ok"; \
            else \
                echo "$h: FAILED"; echo "$h" >> "$tmp/failed"; \
            fi; \
        fi; \
    done; \
    echo; \
    if [ -s "$tmp/failed" ]; then \
        echo "FAILED: $(tr '\n' ' ' < "$tmp/failed")"; \
        exit 1; \
    fi; \
    echo "done"

# Pull + switch on hosts you select from the fleet menu.
deploy-all:
    @just hosts-run deploy

# Reboot hosts you select from the fleet menu.
reboot-all:
    @just hosts-run reboot

# Format all .nix files (nixfmt)
format:
    ./format.sh

# --- managing secrets --------------------------------------------------------
# The recipes below use `sops`, which is installed on sops hosts via
# common/sops.nix (`environment.systemPackages`).

# Needs a local age key (SOPS_AGE_KEY_FILE, ~/.config/sops/age/keys.txt, or
# from common/sops.nix on sops hosts).
# Edit the secrets file.
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

# Run after adding/removing a key in .sops.yaml so the encrypted file gains
# or drops that recipient.
# Re-encrypt secrets for every recipient in .sops.yaml.
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

# Generate the missing .pub file for each private key in ~/.ssh (id_*).
# Passphrase-protected keys use {{passphrase}} if set, otherwise ssh-keygen
# prompts interactively. Existing .pub files are kept unless --force=true.
# Generate .pub files for all private keys in ~/.ssh.
[arg("force", long="force")]
pubkeys force="false":
    @for f in ~/.ssh/id_*; do \
        [ -f "$f" ] || continue; \
        case "$f" in *.pub) continue;; esac; \
        if [ -f "$f.pub" ] && [ "{{ force }}" != "true" ]; then \
            echo "skip: $f.pub already exists (use --force=true to overwrite)"; \
            continue; \
        fi; \
        echo "==> generating $f.pub"; \
        if [ -n "{{ passphrase }}" ]; then \
            ssh-keygen -y -f "$f" -P "{{ passphrase }}" > "$f.pub"; \
        else \
            ssh-keygen -y -f "$f" > "$f.pub"; \
        fi; \
    done

# Derived pubkey should match .sops.yaml unless you are rotating keys.
# Print the age public key for {{ssh_key}}.
key-pub:
    @{{ ssh_to_age }} < {{ ssh_key }}.pub

# Used for sops editing or copying onto a fresh machine.
# Derive the age private key and save it to a file (default ~/age-key.txt).
key-generate out=age_key_file:
    @if [ -n "{{ passphrase }}" ]; then export SSH_TO_AGE_PASSPHRASE='{{ passphrase }}'; fi
    @{{ ssh_to_age }} -private-key -i {{ ssh_key }} > {{ out }} || { rm -f {{ out }}; exit 1; }
    @chmod 600 {{ out }}
    @echo "wrote age key to {{ out }}"

# For fresh installs or rotation; refuses unless the derived pubkey is listed
# in .sops.yaml (check with `just key-pub`).
# Install the age key on this machine.
key-install:
    @derived="$({{ ssh_to_age }} < {{ ssh_key }}.pub)"; \
    grep -qF "$derived" .sops.yaml || { \
        echo "error: pubkey $derived is not in .sops.yaml; add it there first (or check ssh_key={{ ssh_key }})" >&2; \
        exit 1; \
    }
    @if [ -n "{{ passphrase }}" ]; then export SSH_TO_AGE_PASSPHRASE='{{ passphrase }}'; fi
    sudo mkdir -p {{ age_key_dir }}
    {{ ssh_to_age }} -private-key -i {{ ssh_key }} | sudo tee {{ age_key_path }} > /dev/null
    sudo chmod 400 {{ age_key_path }}
    @echo "installed age key at {{ age_key_path }}"

# Requires ssh access as {{user}} and passwordless sudo on the target.
# Install the age key on a remote host over ssh.
key-install-remote host:
    @derived="$({{ ssh_to_age }} < {{ ssh_key }}.pub)"; \
    grep -qF "$derived" .sops.yaml || { \
        echo "error: pubkey $derived is not in .sops.yaml; add it there first (or check ssh_key={{ ssh_key }})" >&2; \
        exit 1; \
    }
    @if [ -n "{{ passphrase }}" ]; then export SSH_TO_AGE_PASSPHRASE='{{ passphrase }}'; fi
    ssh {{ user }}@{{ host }} "sudo mkdir -p {{ age_key_dir }}"
    {{ ssh_to_age }} -private-key -i {{ ssh_key }} | ssh {{ user }}@{{ host }} "sudo tee {{ age_key_path }} > /dev/null && sudo chmod 400 {{ age_key_path }}"
    @echo "installed age key on {{ host }}"

# Current host is done locally, the rest over ssh; fails fast on the first
# unreachable host.
# Install the age key on every sops host.
key-install-all:
    @for h in {{ sops_hosts }}; do \
        echo "==> installing age key on $h"; \
        if [ "$h" = "{{ hostname }}" ]; then \
            SSH_TO_AGE_PASSPHRASE='{{ passphrase }}' just key-install; \
        else \
            SSH_TO_AGE_PASSPHRASE='{{ passphrase }}' just key-install-remote "$h"; \
        fi; \
    done

# Run as root, passing the ssh key path explicitly since root's ~ is /root:
#   sudo just fresh-install-key /mnt --set ssh_key /home/cjdell/.ssh/id_ed25519_ps
# For use before nixos-install, after scripts/mount-partitions.sh.
# Provision the age key into a freshly mounted target root.
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
#        just key-install-all
# Walk through the documented key-rotation steps.
key-rotate:
    @echo "following the documented order above (update keys, then install everywhere):"
    just key-update
    just key-install-all
