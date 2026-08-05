#!/usr/bin/env bash

find . -iname '*.nix' | xargs nixfmt
