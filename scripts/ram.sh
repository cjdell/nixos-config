#!/usr/bin/env bash

sudo dmidecode -t 17 | awk 'BEGIN { FS=":"; OFS="\t" } /Size|Channel/ { line = (line ? line OFS : "") $2 } /^$/ { print line; line="RAM" }' | grep -iv 'no'
