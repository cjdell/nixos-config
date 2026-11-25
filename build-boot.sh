#!/usr/bin/env bash
set -euo pipefail

# Boot-build the current host. On autoRollback hosts (N100-NAS, grafton-router)
# follow with: sudo nixos-confirm
sudo nixos-rebuild boot --flake .
