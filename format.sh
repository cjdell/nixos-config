#!/usr/bin/env bash
set -euo pipefail

find . -iname '*.nix' -not -path './result/*' -print0 | xargs -0 -r nixfmt
