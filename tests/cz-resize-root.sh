#!/bin/bash
# Unit tests for resize-root, the userspace replacement for the initramfs
# ` resize` path (resize_early + set_partuuid). That path hung on this board
# before switch_root, so 02-run.sh drops the token and this script grows the
# root filesystem from a first-boot service instead.
#
# Three traps, all of which were hit on real hardware:
#   1. parted prompts "Partition ... is being used" when root is mounted and,
#      with no tty under systemd, exits 1 - the 2026-11-26 22:03 failure. Hence
#      growpart, and an assertion that parted is never invoked.
#   2. Rewriting the partition table does not resize the filesystem, and without
#      a kernel re-read resize2fs silently grows nothing and exits 0.
#   3. Raspberry Pi Imager expands the last partition itself but stops 33
#      sectors short of the end, so growpart answers NOCHANGE. Demanding the
#      partition end exactly at disk_size-1 - as the first version did - turned
#      that into a hard failure on the 2026-11-26 23:08 boot and left a 28.6G
#      partition holding a 2.6G filesystem at 93% full.
# Run: bash tests/cz-resize-root.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CZ="$HERE/../stage2/05-cardputerzero/files/resize-root"
UNIT="$HERE/../stage2/05-cardputerzero/files/cardputerzero-resize.service"
INSTALL="$HERE/../stage2/05-cardputerzero/01-run.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MOCK="$WORK/bin"; mkdir -p "$MOCK"
SYS="$WORK/sys"
export CZLOG="$WORK/calls.log"
export CZ_TABLE_OK="$WORK/table_ok"
export CZ_RESIZE_SYS="$SYS"
export CZ_RESIZE_DONE="$WORK/etc/cardputerzero/resize.done"

# Real geometry of the 29.1G card: 61069312 sectors, rootfs starting at 1064960
# and shipped at 2.6G. 60004319 is what Raspberry Pi Imager actually leaves
# behind - 33 sectors short of the end of the disk.
DISK_SECTORS=61069312
PART_START=1064960
FRESH_SIZE=5472256
IMAGER_SIZE=60004319
GROWN_END=$(( DISK_SECTORS - PART_START - 33 ))

printf '#!/bin/sh\necho /dev/mmcblk0p2\n' > "$MOCK/findmnt"
cat > "$MOCK/lsblk" <<'EOF'
#!/bin/sh
case "$2" in
  KNAME)  echo mmcblk0p2 ;;
  PKNAME) echo mmcblk0 ;;
esac
EOF
# growpart rewrites the table, but the kernel keeps the old size until partx
# tells it - so do NOT touch sysfs here. NOCHANGE (exit 1) is the normal answer
# once the partition already spans the usable space.
cat > "$MOCK/growpart" <<'EOF'
#!/bin/sh
printf 'growpart %s\n' "$*" >> "$CZLOG"
rm -f "$CZ_TABLE_OK"
[ "${CZ_TEST_GROWPART_NOCHANGE:-0}" = 1 ] && { echo "NOCHANGE: partition $2 is size 1. it cannot be grown"; exit 1; }
: > "$CZ_TABLE_OK"
EOF
cat > "$MOCK/partx" <<'EOF'
#!/bin/sh
printf 'partx %s\n' "$*" >> "$CZLOG"
[ "${CZ_TEST_PARTX_FAIL:-0}" = 1 ] && exit 1
[ -e "$CZ_TABLE_OK" ] || exit 0
printf '%s' "$GROWN_END_MOCK" > "$CZ_SIZE_FILE"
EOF
cat > "$MOCK/partprobe" <<'EOF'
#!/bin/sh
printf 'partprobe %s\n' "$*" >> "$CZLOG"
# Realistic default: EBUSY, because the partition being grown is the live root.
[ "${CZ_TEST_PARTPROBE_OK:-0}" = 1 ] || exit 1
[ -e "$CZ_TABLE_OK" ] || exit 0
printf '%s' "$GROWN_END_MOCK" > "$CZ_SIZE_FILE"
EOF
# df is how the script proves resize2fs actually did something.
cat > "$MOCK/df" <<'EOF'
#!/bin/sh
printf 'Size\n%s\n' "$CZ_TEST_FS_BYTES"
EOF
# Recorded only so the tests can prove parted is never reached.
printf '#!/bin/sh\nprintf "parted %%s\\n" "$*" >> "$CZLOG"\n' > "$MOCK/parted"
printf '#!/bin/sh\nprintf "resize2fs %%s\\n" "$*" >> "$CZLOG"\n' > "$MOCK/resize2fs"
chmod +x "$MOCK"/*
export GROWN_END_MOCK="$GROWN_END"
# resize-root sets its own PATH so growpart can find sfdisk in /usr/sbin; the
# mocks have to stay ahead of it or the test silently runs against the host's
# own root device.
export CZ_RESIZE_PATH="$MOCK:$PATH"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
calls() { cat "$CZLOG" 2>/dev/null; }

mkfixture() { # disk_sectors part_start part_size part_num
    rm -rf "$SYS" "$WORK/etc"; rm -f "$CZ_TABLE_OK"
    mkdir -p "$SYS/block/mmcblk0/mmcblk0p2"
    printf '%s' "$1" > "$SYS/block/mmcblk0/size"
    printf '%s' "$2" > "$SYS/block/mmcblk0/mmcblk0p2/start"
    printf '%s' "$3" > "$SYS/block/mmcblk0/mmcblk0p2/size"
    printf '%s' "$4" > "$SYS/block/mmcblk0/mmcblk0p2/partition"
    export CZ_SIZE_FILE="$SYS/block/mmcblk0/mmcblk0p2/size"
    export CZ_TEST_FS_BYTES=$(( GROWN_END * 512 ))
    : > "$CZLOG"
    unset CZ_TEST_PARTX_FAIL CZ_TEST_PARTPROBE_OK CZ_TEST_GROWPART_NOCHANGE
}
run() { out=$(env PATH="$MOCK:$PATH" bash "$CZ" 2>&1); rc=$?; }

echo "=== freshly flashed card, nothing has grown the partition yet ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 2
run
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $out"
case "$(calls)" in *"growpart /dev/mmcblk0 2"*) ok "grew the partition with growpart" ;;
    *) bad "wrong growpart call: $(calls | grep growpart)" ;; esac
case "$(calls)" in *parted*) bad "invoked parted - it prompts and dies under systemd" ;;
    *) ok "never invoked parted" ;; esac
case "$(calls)" in *"partx --update /dev/mmcblk0"*) ok "re-read the table with partx" ;;
    *) bad "never called partx --update" ;; esac
case "$(calls)" in *"resize2fs /dev/mmcblk0p2"*) ok "grew the filesystem" ;;
    *) bad "never called resize2fs: $(calls)" ;; esac
case "$out" in *"grew from $FRESH_SIZE to $GROWN_END"*) ok "reported the partition growth" ;;
    *) bad "did not report growth: $out" ;; esac
[ -e "$CZ_RESIZE_DONE" ] && ok "wrote the retry marker" || bad "no marker - the service would run on every boot"

echo "=== Imager already grew it: growpart says NOCHANGE (the 23:08 failure) ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$IMAGER_SIZE" 2
export CZ_TEST_GROWPART_NOCHANGE=1
run
[ "$rc" = 0 ] && ok "exit 0 despite growpart's NOCHANGE" || bad "exit $rc: $out"
case "$out" in *"growpart made no change"*) ok "reported the NOCHANGE" ;;
    *) bad "NOCHANGE not surfaced: $out" ;; esac
case "$(calls)" in *resize2fs*) ok "still ran resize2fs - this is the case that was being skipped" ;;
    *) bad "skipped resize2fs, leaving a 2.6G filesystem on a 28.6G partition" ;; esac
[ -e "$CZ_RESIZE_DONE" ] && ok "wrote the marker" || bad "no marker"

echo "=== growpart cannot grow and the partition really is still small ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 2
export CZ_TEST_GROWPART_NOCHANGE=1
run
[ "$rc" = 1 ] && ok "exit 1 rather than pretending to succeed" || bad "exit $rc"
case "$out" in *"sectors still unused at the end"*) ok "names the ungrown partition" ;;
    *) bad "no useful diagnostic: $out" ;; esac
case "$(calls)" in *resize2fs*) bad "ran resize2fs on a partition that never grew" ;;
    *) ok "did not run resize2fs" ;; esac
[ -e "$CZ_RESIZE_DONE" ] && bad "wrote the marker despite failing - no retry would happen" \
    || ok "left the marker unwritten so the next boot retries"

echo "=== resize2fs silently does nothing: the filesystem check catches it ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$IMAGER_SIZE" 2
export CZ_TEST_GROWPART_NOCHANGE=1
export CZ_TEST_FS_BYTES=$(( FRESH_SIZE * 512 ))
run
[ "$rc" = 1 ] && ok "exit 1 on a no-op resize2fs" || bad "exit $rc - a silent no-op resize"
case "$out" in *"resize2fs did not grow it"*) ok "says the filesystem is still small" ;;
    *) bad "no diagnostic: $out" ;; esac
[ -e "$CZ_RESIZE_DONE" ] && bad "marked done after a no-op resize" || ok "no marker written"

echo "=== kernel never learns the new size ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 2
export CZ_TEST_PARTX_FAIL=1
run
[ "$rc" = 1 ] && ok "exit 1 instead of claiming success" || bad "exit $rc"
case "$(calls)" in *resize2fs*) bad "called resize2fs against a stale partition size" ;;
    *) ok "did not run resize2fs against the old size" ;; esac

echo "=== partprobe fallback when partx is unavailable ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 2
export CZ_TEST_PARTX_FAIL=1 CZ_TEST_PARTPROBE_OK=1
run
[ "$rc" = 0 ] && ok "exit 0 via the partprobe fallback" || bad "exit $rc: $out"
case "$(calls)" in *partprobe*) ok "fell back to partprobe" ;;
    *) bad "no partprobe attempt: $(calls)" ;; esac
case "$(calls)" in *resize2fs*) ok "grew the filesystem after the fallback" ;;
    *) bad "no resize2fs after a successful partprobe" ;; esac

echo "=== root not on partition 2: leave the disk alone ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 3
run
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $out"
case "$out" in *"unexpected partition layout"*) ok "explains the skip" ;;
    *) bad "no explanation: $out" ;; esac
case "$(calls)" in *growpart*|*resize2fs*) bad "touched the disk anyway: $(calls)" ;;
    *) ok "changed nothing" ;; esac

echo "=== growpart can find sfdisk, which lives in /usr/sbin ==="
grep -qE '^PATH=.*/usr/sbin' "$CZ" && ok "sets a PATH containing /usr/sbin" \
    || bad "no explicit PATH - growpart fails with 'Did not have sfdisk or sgdisk in PATH'"

echo "=== unit wiring: it must be able to retry after a failure ==="
grep -q '^ConditionPathExists=!/etc/cardputerzero/resize.done$' "$UNIT" \
    && ok "gated on the marker the script writes" || bad "unit is not gated on the marker"
grep -q '^ConditionFirstBoot' "$UNIT" && bad "ConditionFirstBoot is back - a failed first boot could never retry" \
    || ok "no ConditionFirstBoot directive"
grep -q '^ExecStartPost=.*disable' "$UNIT" && bad "still self-disables, which also blocks retries" \
    || ok "does not self-disable"
SCRIPT_DONE=$(sed -n 's|^DONE=${CZ_RESIZE_DONE:-\(.*\)}$|\1|p' "$CZ")
UNIT_DONE=$(sed -n 's|^ConditionPathExists=!\(.*\)$|\1|p' "$UNIT")
[ -n "$SCRIPT_DONE" ] && [ "$SCRIPT_DONE" = "$UNIT_DONE" ] \
    && ok "script and unit agree on $SCRIPT_DONE" \
    || bad "marker path mismatch: script=$SCRIPT_DONE unit=$UNIT_DONE"
EXEC=$(sed -n 's|^ExecStart=\(.*\)$|\1|p' "$UNIT")
grep -qF "\"\${ROOTFS_DIR}${EXEC}\"" "$INSTALL" \
    && ok "installed where the unit expects ($EXEC)" \
    || bad "ExecStart $EXEC is not installed by 01-run.sh"

echo "=== growpart is a declared dependency, not a transitive accident ==="
grep -q '^cloud-guest-utils$' "$HERE/../stage2/05-cardputerzero/00-packages" \
    && ok "cloud-guest-utils declared in 00-packages" \
    || bad "growpart only present transitively - a build could drop it"

echo
if [ "$fail" = 0 ]; then echo "CZ-RESIZE-ROOT OK"; else echo "CZ-RESIZE-ROOT PROBLEM"; exit 1; fi
