#!/usr/bin/env bash
set -eo pipefail

stress-ng -c 6 -i 2 -m 2 --vm-bytes 128M -t 1000s
