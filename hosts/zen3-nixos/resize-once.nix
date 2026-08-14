# One-time partition resize for zen3-nixos.
#
# !! DISABLED / COMPLETED on 2026-08-14: the resize ran successfully
# !! (/ 181G -> 250G, /home 750G -> ~681G). The import in default.nix is
# !! commented out. This file is kept as documentation and for possible
# !! reuse (update the geometry constants + run the arming steps below).
# !! Full write-up: docs/resize-once.md
#
# Goal: grow the root partition (WD_BLACK SN770 1TB) from 181G to 250G,
# taking the space from /home (750G -> ~681G).
#
# Why an initrd service? The root partition is the LAST partition on the
# disk, so growing it requires moving its start point ~69G to the left,
# i.e. physically relocating the root filesystem. That can never happen
# while / is mounted (stage 2), so this runs as a one-shot systemd service
# inside the *initrd* (stage 1), before / or /home is mounted.
#
# Arming (one time, run as root on zen3-nixos):
#   sudo nixos-rebuild switch --impure --flake . --max-jobs 1
#   sudo nixos-confirm              # autoRollback host - mandatory!
#   sudo touch /resize-once.flag
#   sudo reboot
#
# The flag file lives at the root of the root filesystem (NOT on the ESP).
# It is read and removed with debugfs, so the initrd never has to mount
# anything - mounting the vfat ESP from the initrd proved unreliable on this
# host. The progress log is written back into the fs as /resize-once.log so
# it survives the reboot and can be inspected on the booted system.
#
# On failure before the root move the system boots unchanged and the log
# records why. On failure during the move the machine powers off (do not
# boot a half-moved root).
#
# Devices are resolved by fs UUID (never by /dev/nvmeXn1Y paths): this host
# has two NVMe drives whose kernel names swap between boots (observed: the
# WD Black has been both nvme0n1 and nvme1n1), so path-based references are
# not stable.
#
# fs UUIDs are preserved throughout (nothing is reformatted), so NixOS keeps
# mounting / and /home by UUID with no config changes.
#
# Preflight (read-only, run before arming):
#   scripts/check-resize-once.sh
#
# Verification after reboot:
#   cat /resize-once.log && lsblk && df -h /
#
# This module is inert unless the flag file exists; it can be left in place.
{ pkgs, ... }:

{
  boot.initrd.systemd.services.resize-once = {
    description = "One-time root resize: shrink /home and grow / to 250G";
    wantedBy = [ "initrd.target" ];
    before = [ "sysroot.mount" ];
    enableStrictShellChecks = false;
    serviceConfig = {
      Type = "oneshot";
      # The fs move + fsck can take several minutes; the default 90s timeout
      # would kill the copy mid-flight.
      TimeoutStartSec = "infinity";
    };
    script = ''
      # ---------------------------------------------------------------------
      # Constants: geometry of the root disk in 512-byte sectors, and the fs
      # UUIDs used for device resolution. Verified against the live system by
      # scripts/check-resize-once.sh.
      # ---------------------------------------------------------------------
      ROOT_UUID=4424123b-847e-4379-b505-520c85e522dd
      HOME_UUID=a4284946-7e9b-4bcf-a94a-fa3e5a19e283
      PART3_GUID=b97cf146-7932-40e0-89a0-39dce773fb2a
      PART5_GUID=1d9d255b-4b3c-4440-9333-4810b7206f86

      # expected current geometry (sectors)
      EXPECT_DISK_SIZE=1953525168
      EXPECT_P3_START=1573990400
      EXPECT_P3_SIZE=379534735
      EXPECT_P5_START=1126400
      EXPECT_P5_SIZE=1572864000

      # target geometry (sectors): / grows to 250G, /home shrinks to ~681G
      NEW_P5_END=1429237759
      NEW_P3_START=1429237760
      NEW_P3_END=1953525134
      # /home target size in 4K blocks (1428111360 sectors / 8)
      P5_BLOCKS=178513920
      # dd offsets in 4K blocks for the root fs image move
      DD_SKIP=196748800   # 1573990400 / 8
      DD_SEEK=178654720   # 1429237760 / 8

      # flag/log live at the root of the root fs, read/written via debugfs
      FLAG_PATH=/resize-once.flag
      LOG_PATH=/resize-once.log
      LOG=/run/resize-once.log

      log() {
        echo "$(date '+%F %T') $1" >> "$LOG"
      }

      # Copy the running log into the root fs. The fs is not mounted at this
      # point (we run before sysroot.mount), so debugfs write access works.
      save_log() {
        debugfs -w -R "write $LOG $LOG_PATH" "$P3" >/dev/null 2>&1 || true
      }

      # Abort while the system is still bootable (root untouched): record
      # the failure in the log and continue booting.
      abort() {
        log "ABORT: $1"
        save_log
        exit 0
      }

      # Fatal error once the root fs move has begun: stop the machine rather
      # than continue booting a half-moved root.
      fatal() {
        log "FATAL: $1"
        save_log
        sync
        poweroff -f 2>/dev/null || systemctl poweroff 2>/dev/null || true
        exit 1
      }

      # ---------------------------------------------------------------------
      # 1. Resolve devices by fs UUID (NVMe enumeration is not stable across
      #    boots on this host).
      # ---------------------------------------------------------------------
      udevadm settle --timeout=30 || true
      for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -e /dev/disk/by-uuid/$ROOT_UUID ] && [ -e /dev/disk/by-uuid/$HOME_UUID ] && break
        sleep 1
      done
      [ -e /dev/disk/by-uuid/$ROOT_UUID ] || { echo "resize-once: root partition (UUID $ROOT_UUID) not found, skipping"; exit 0; }
      [ -e /dev/disk/by-uuid/$HOME_UUID ] || { echo "resize-once: home partition (UUID $HOME_UUID) not found, skipping"; exit 0; }

      P3_NAME=$(basename "$(readlink -f /dev/disk/by-uuid/$ROOT_UUID)")
      P5_NAME=$(basename "$(readlink -f /dev/disk/by-uuid/$HOME_UUID)")
      P3=/dev/$P3_NAME
      P5=/dev/$P5_NAME
      DISK=/dev/$(echo "$P3_NAME" | sed -E 's/p?[0-9]+$//')
      P3_NUM=$(echo "$P3_NAME" | grep -oE '[0-9]+$')
      P5_NUM=$(echo "$P5_NAME" | grep -oE '[0-9]+$')

      # ---------------------------------------------------------------------
      # 2. Arming flag at the root of the root fs. No flag -> boot normally.
      # ---------------------------------------------------------------------
      if ! debugfs -R "stat $FLAG_PATH" "$P3" 2>/dev/null | grep -q 'Inode:'; then
        exit 0
      fi

      : > "$LOG"
      log "=== resize-once start ==="
      debugfs -w -R "rm $FLAG_PATH" "$P3" >/dev/null 2>&1 || abort "failed to remove flag"
      save_log

      # ---------------------------------------------------------------------
      # 3. Sanity-check the disk against the expected geometry/UUIDs.
      # ---------------------------------------------------------------------
      CUR_P3_START=$(cat /sys/class/block/$P3_NAME/start)
      CUR_P3_SIZE=$(cat /sys/class/block/$P3_NAME/size)
      CUR_P5_START=$(cat /sys/class/block/$P5_NAME/start)
      CUR_P5_SIZE=$(cat /sys/class/block/$P5_NAME/size)
      CUR_DISK_SIZE=$(cat /sys/class/block/$(basename "$DISK")/size)
      [ "$CUR_P3_START" = "$EXPECT_P3_START" ] || abort "p3 start mismatch: $CUR_P3_START"
      [ "$CUR_P3_SIZE" = "$EXPECT_P3_SIZE" ] || abort "p3 size mismatch: $CUR_P3_SIZE"
      [ "$CUR_P5_START" = "$EXPECT_P5_START" ] || abort "p5 start mismatch: $CUR_P5_START"
      [ "$CUR_P5_SIZE" = "$EXPECT_P5_SIZE" ] || abort "p5 size mismatch: $CUR_P5_SIZE"
      [ "$CUR_DISK_SIZE" = "$EXPECT_DISK_SIZE" ] || abort "disk size mismatch: $CUR_DISK_SIZE"

      ROOT_FS_UUID=$(dumpe2fs -h "$P3" 2>/dev/null | grep 'Filesystem UUID' | tr -s ' ' | cut -d' ' -f3)
      HOME_FS_UUID=$(dumpe2fs -h "$P5" 2>/dev/null | grep 'Filesystem UUID' | tr -s ' ' | cut -d' ' -f3)
      [ "$ROOT_FS_UUID" = "$ROOT_UUID" ] || abort "root fs UUID mismatch: $ROOT_FS_UUID"
      [ "$HOME_FS_UUID" = "$HOME_UUID" ] || abort "home fs UUID mismatch: $HOME_FS_UUID"
      log "geometry checks passed"

      # ---------------------------------------------------------------------
      # 4. Phase 0: shrink /home (p5). A failure here leaves the system
      #    bootable, so we abort (continue booting) instead of powering off.
      # ---------------------------------------------------------------------
      log "e2fsck -fy $P5"
      e2fsck -fy "$P5" >> "$LOG" 2>&1 || abort "e2fsck failed on $P5"
      log "resize2fs $P5 -> $P5_BLOCKS 4K blocks"
      resize2fs "$P5" "$P5_BLOCKS" >> "$LOG" 2>&1 || abort "resize2fs failed on $P5"

      log "shrinking partition p$P5_NUM (end sector -> $NEW_P5_END)"
      sgdisk --delete=$P5_NUM --new=$P5_NUM:1126400:$NEW_P5_END \
        --partition-guid=$P5_NUM:$PART5_GUID \
        --change-name=$P5_NUM:'Linux filesystem' "$DISK" >> "$LOG" 2>&1 || abort "sgdisk failed shrinking p5"
      blockdev --rereadpt "$DISK" >> "$LOG" 2>&1 || abort "rereadpt failed after p5 shrink"
      log "p5 shrunk"
      save_log

      # ---------------------------------------------------------------------
      # 5. Phase 1: move the root fs (p3). From here on any failure stops
      #    the machine (point of no return).
      # ---------------------------------------------------------------------
      log "=== Phase 1: move root fs (point of no return) ==="
      save_log
      e2fsck -fy "$P3" >> "$LOG" 2>&1 || fatal "e2fsck failed on $P3"
      resize2fs -M "$P3" >> "$LOG" 2>&1 || fatal "resize2fs -M failed on $P3"
      F=$(dumpe2fs -h "$P3" 2>/dev/null | grep 'Block count' | tr -s ' ' | cut -d' ' -f3)
      [ -n "$F" ] || fatal "could not read block count"
      [ "$F" -gt 1000000 ] || fatal "suspicious block count: $F"
      [ "$F" -lt 47000000 ] || fatal "suspicious block count: $F"
      log "minimised root fs is $F blocks"

      # Copy the (minimal) fs image leftwards. Forward order is safe because
      # the destination is BEFORE the source, so writes never clobber blocks
      # that have not been read yet.
      log "copying $F 4K blocks from offset $DD_SKIP to $DD_SEEK"
      dd if="$DISK" of="$DISK" bs=4096 skip=$DD_SKIP seek=$DD_SEEK count=$F \
        conv=fsync status=none >> "$LOG" 2>&1 || fatal "dd move failed"
      sync

      log "moving partition p$P3_NUM (start sector -> $NEW_P3_START)"
      sgdisk --delete=$P3_NUM --new=$P3_NUM:$NEW_P3_START:$NEW_P3_END \
        --partition-guid=$P3_NUM:$PART3_GUID "$DISK" >> "$LOG" 2>&1 || fatal "sgdisk failed on p3"
      blockdev --rereadpt "$DISK" >> "$LOG" 2>&1 || fatal "rereadpt failed after p3 move"

      for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -b "$P3" ] && break
        sleep 1
      done
      [ -b "$P3" ] || fatal "block device $P3 missing after rereadpt"

      log "growing root fs to fill the 250G partition"
      e2fsck -fy "$P3" >> "$LOG" 2>&1 || fatal "e2fsck failed on moved $P3"
      resize2fs "$P3" >> "$LOG" 2>&1 || fatal "resize2fs grow failed on $P3"
      e2fsck -fy "$P3" >> "$LOG" 2>&1 || fatal "final e2fsck failed on $P3"

      # ---------------------------------------------------------------------
      # 6. Record success (the fs has moved, but $P3 now points at the moved
      #    partition, so the log lands in the new root fs) and boot normally.
      # ---------------------------------------------------------------------
      log "resize-once COMPLETE"
      save_log
      exit 0
    '';
  };

  boot.initrd.systemd.extraBin = {
    e2fsck = "${pkgs.e2fsprogs}/bin/e2fsck";
    resize2fs = "${pkgs.e2fsprogs}/bin/resize2fs";
    dumpe2fs = "${pkgs.e2fsprogs}/bin/dumpe2fs";
    debugfs = "${pkgs.e2fsprogs}/bin/debugfs";
    sgdisk = "${pkgs.gptfdisk}/bin/sgdisk";
    blockdev = "${pkgs.util-linux}/bin/blockdev";
    grep = "${pkgs.gnugrep}/bin/grep";
    sed = "${pkgs.gnused}/bin/sed";
  };
}
