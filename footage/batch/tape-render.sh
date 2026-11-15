#!/run/current-system/sw/bin/bash
# Generic render wrapper. $1=stitched in $2=watch out $3=osd-rect (or "" for
# none). Robust-ME confirmed recipe. F@H parked/restored. Terminal markers.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
KIT=$HOME/nixos-config/result/bin/footage-clean
SUDO=/run/wrappers/bin/sudo
IN="$1"; OUT="$2"; OSD="${3:-}"; TO="${4:-}"
echo "$(date +%F_%T) stopping fah-client"
$SUDO -n systemctl stop fah-client
ARGS=(--deint auto --denoise none --codec nvenc-hevc --crf 16 --preset slow
      --single-pass --source-color --me-search 5 --me-searchparam 3
      --me-range 32 --me-divide --me-rblk 16 --deint-degrain 0)
[ -n "$OSD" ] && ARGS+=(--osd-rect "$OSD")
[ -n "$TO" ] && ARGS+=(--to "$TO")
"$KIT" "${ARGS[@]}" "$IN" "$OUT"
rc=$?
echo "$(date +%F_%T) footage-clean exit=$rc"
$SUDO -n systemctl start fah-client && echo "$(date +%F_%T) fah-client restarted"
if [ $rc -eq 0 ]; then echo "$(date +%F_%T) DONE $(du -h "$OUT" | cut -f1)"; else echo "$(date +%F_%T) FAIL"; fi
exit $rc
