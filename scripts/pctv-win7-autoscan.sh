#!/usr/bin/env bash
#
# Make the `win7` libvirt domain follow the PCTV 320cx (2304:022e) across its
# mode-switch re-enumeration.
#
# Why: libvirt resolves a USB hostdev's <vendor>/<product> to a fixed
# `hostdevice=/dev/bus/usb/<bus>/<dev>` at domain start and pins it there. The
# PCTV re-enumerates when its Windows driver changes mode, so that pinned path
# goes stale ("libusb_release_interface: -4 [NO_DEVICE]") and the guest loses the
# card. QEMU's own `usb-host` *autoscan* (matched on vendorid/productid, polled
# every 2s) follows the card, but libvirt never emits those properties.
#
# This script rewrites the persistent domain XML so QEMU gets:
#   - `hostdevice` REMOVED
#   - `vendorid`/`productid`/`hostport`  -> autoscan
#   - `guest-reset=off`                  -> guest port resets don't reset the card
#
# Run:  sudo ./scripts/pctv-win7-autoscan.sh
# It is idempotent, only redefines the domain when something changed, and does
# not touch a running guest (the new XML applies on the next start). See
# docs/pctv-320cx.md.

set -euo pipefail

DOMAIN="${1:-win7}"
VIRSH=(virsh --connect qemu:///system)
QEMU_NS="http://libvirt.org/schemas/domain/qemu/1.0"

TMP="$(mktemp /tmp/pctv-win7-XXXXXX.xml)"
trap 'rm -f "$TMP"' EXIT
SRC="$(mktemp /tmp/pctv-win7-src-XXXXXX.xml)"
trap 'rm -f "$TMP" "$SRC"' EXIT

"${VIRSH[@]}" dumpxml --inactive "$DOMAIN" > "$SRC"

# 1. qemu namespace on <domain ...>
if ! grep -q 'xmlns:qemu=' "$SRC"; then
  sed -i "0,/<domain /s#<domain #<domain xmlns:qemu='$QEMU_NS' #" "$SRC"
fi

# 2. guestReset='off' on the PCTV hostdev source (only inside a <hostdev> block)
sed -i "/<hostdev /,/<\/hostdev>/ s#^\(\s*\)<source>\$#\1<source guestReset='off'>#" "$SRC"

# 3. qemu:override swapping the pinned hostdevice for autoscan matching
if ! grep -q 'qemu:override' "$SRC"; then
  cat > "$TMP" <<'EOF'
  <qemu:override>
    <qemu:device alias='hostdev0'>
      <qemu:frontend>
        <qemu:property name='hostdevice' type='remove'/>
        <qemu:property name='vendorid' type='unsigned' value='8964'/>
        <qemu:property name='productid' type='unsigned' value='558'/>
        <qemu:property name='hostport' type='string' value='3'/>
      </qemu:frontend>
    </qemu:device>
  </qemu:override>
EOF
  awk -v blk="$(cat "$TMP")" \
      '{ if ($0 ~ /^<\/domain>/) print blk; print }' "$SRC" > "$SRC.new"
  mv "$SRC.new" "$SRC"
fi

# 4. redefine only if changed
if diff -q <("${VIRSH[@]}" dumpxml --inactive "$DOMAIN" | sed '/^$/d') \
           <(sed '/^$/d' "$SRC") >/dev/null 2>&1; then
  echo "already up to date: $DOMAIN"
  exit 0
fi

"${VIRSH[@]}" define "$SRC"
echo "updated: $DOMAIN (autoscan override applied; takes effect on next start)"
