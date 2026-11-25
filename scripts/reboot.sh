#!/usr/bin/env bash
set -eo pipefail

# Ensure disk write buffers are flushed to physical disk
sync

# Do a hard reboot (no systemd faffing around which can potentially hang the system)
echo b > /proc/sysrq-trigger
