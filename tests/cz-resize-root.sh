#!/bin/bash
# Unit tests for resize-root, the userspace replacement for the initramfs
# ` resize` path (resize_early + set_partuuid). That path hung on this board
# before switch_root, so 02-run.sh drops the token and this script grows the
# root filesystem from a first-boot service instead.
#
# Two traps this covers, both of which were hit on real hardware:
#   1. parted prompts "Partition ... is being used. Are you sure you want to
#      continue?" when root is already mounted, and with no tty under systemd it
#      exits 1 - the 2026-11-26 22:03 first boot failed exactly this way. Hence
#      growpart, and an assertion that parted is never invoked.
#   2. Rewriting the partition table does not resize the filesystem. Without a
#      kernel re-read resize2fs silently grows nothing and exits 0, so the
#      script must fail loudly and leave the retry marker unwritten.
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

# Geometry of the real 29.1G card: 61069312 sectors, rootfs starting at 1064960
# and shipped at 2.6G, so the target end is 61069311 and the target size the
# 60004352 sectors resize_early left behind on the failed boot.
DISK_SECTORS=61069312
PART_START=1064960
FRESH_SIZE=5472256
GROWN_SIZE=60004352

printf '#!/bin/sh\necho /dev/mmcblk0p2\n' > "$MOCK/findmnt"
cat > "$MOCK/lsblk" <<'EOF'
#!/bin/sh
case "$2" in
  KNAME)  echo mmcblk0p2 ;;
  PKNAME) echo mmcblk0 ;;
esac
EOF
# growpart rewrites the table but the kernel keeps the old size until partx
# tells it, so deliberately do NOT touch sysfs here. It records whether the
# table was actually rewritten, because partx can only report what is in it -
# a mock that grew the size after a failed growpart would hide a real bug.
cat > "$MOCK/growpart" <<'EOF'
#!/bin/sh
printf 'growpart %s\n' "$*" >> "$CZLOG"
rm -f "$CZ_TABLE_OK"
[ "${CZ_TEST_GROWPART_FAIL:-0}" = 1 ] && exit 1
: > "$CZ_TABLE_OK"
EOF
cat > "$MOCK/partx" <<'EOF'
#!/bin/sh
printf 'partx %s\n' "$*" >> "$CZLOG"
[ "${CZ_TEST_PARTX_FAIL:-0}" = 1 ] && exit 1
[ -e "$CZ_TABLE_OK" ] || exit 0
printf '%s' "$CZ_TEST_NEW_SIZE" > "$CZ_SIZE_FILE"
EOF
cat > "$MOCK/partprobe" <<'EOF'
#!/bin/sh
printf 'partprobe %s\n' "$*" >> "$CZLOG"
# Realistic default: EBUSY, because the partition being grown is the live root.
[ "${CZ_TEST_PARTPROBE_OK:-0}" = 1 ] || exit 1
[ -e "$CZ_TABLE_OK" ] || exit 0
printf '%s' "$CZ_TEST_NEW_SIZE" > "$CZ_SIZE_FILE"
EOF
# Recorded only so the tests can prove parted is never reached.
printf '#!/bin/sh\nprintf "parted %%s\\n" "$*" >> "$CZLOG"\n' > "$MOCK/parted"
printf '#!/bin/sh\nprintf "resize2fs %%s\\n" "$*" >> "$CZLOG"\n' > "$MOCK/resize2fs"
chmod +x "$MOCK"/*

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
calls() { cat "$CZLOG" 2>/dev/null; }

mkfixture() { # disk_sectors part_start part_size part_num
    rm -rf "$SYS" "$WORK/etc"; rm -f "$CZ_TABLE_OK"; mkdir -p "$SYS/block/mmcblk0/mmcblk0p2"
    printf '%s' "$1" > "$SYS/block/mmcblk0/size"
    printf '%s' "$2" > "$SYS/block/mmcblk0/mmcblk0p2/start"
    printf '%s' "$3" > "$SYS/block/mmcblk0/mmcblk0p2/size"
    printf '%s' "$4" > "$SYS/block/mmcblk0/mmcblk0p2/partition"
    export CZ_SIZE_FILE="$SYS/block/mmcblk0/mmcblk0p2/size"
    # What the kernel will report once the table is re-read: grow to the capped
    # end of the disk, matching the script's own WANT_SIZE arithmetic.
    local end=$(( $1 - 1 )); [ "$end" -gt 4294967295 ] && end=4294967295
    export CZ_TEST_NEW_SIZE=$(( end - $2 + 1 ))
    : > "$CZLOG"
    unset CZ_TEST_PARTX_FAIL CZ_TEST_PARTPROBE_OK CZ_TEST_GROWPART_FAIL
}
run() { out=$(env PATH="$MOCK:$PATH" bash "$CZ" 2>&1); rc=$?; }

echo "=== freshly flashed card: partition 2.6G on a 29G disk ==="
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
[ -e "$CZ_RESIZE_DONE" ] && ok "wrote the retry marker" || bad "no marker - the service would run on every boot"

echo "=== partition already grown, filesystem not (the state of the failed card) ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$GROWN_SIZE" 2
run
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $out"
case "$(calls)" in *growpart*) bad "ran growpart on an already-grown partition" ;;
    *) ok "skipped the partition grow" ;; esac
case "$out" in *"skipping growpart"*) ok "says why it skipped" ;;
    *) bad "no explanation for the skip: $out" ;; esac
case "$(calls)" in *resize2fs*) ok "still grew the filesystem" ;;
    *) bad "skipped resize2fs, so the card stays at 2.6G" ;; esac
[ -e "$CZ_RESIZE_DONE" ] && ok "wrote the marker" || bad "no marker"

echo "=== kernel never learns the new size: fail loudly, do not mark done ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 2
export CZ_TEST_PARTX_FAIL=1
run
[ "$rc" = 1 ] && ok "exit 1 instead of claiming success" || bad "exit $rc - a silent no-op resize"
case "$out" in *"kernel still reports"*) ok "names the real problem" ;;
    *) bad "no diagnostic: $out" ;; esac
case "$(calls)" in *resize2fs*) bad "called resize2fs against a stale partition size" ;;
    *) ok "did not run resize2fs against the old size" ;; esac
[ -e "$CZ_RESIZE_DONE" ] && bad "wrote the marker despite failing - the retry would never happen" \
    || ok "left the marker unwritten so the next boot retries"

echo "=== partprobe fallback when partx is unavailable ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 2
export CZ_TEST_PARTX_FAIL=1 CZ_TEST_PARTPROBE_OK=1
run
[ "$rc" = 0 ] && ok "exit 0 via the partprobe fallback" || bad "exit $rc: $out"
case "$(calls)" in *partprobe*) ok "fell back to partprobe" ;;
    *) bad "no partprobe attempt: $(calls)" ;; esac
case "$(calls)" in *resize2fs*) ok "grew the filesystem after the fallback" ;;
    *) bad "no resize2fs after a successful partprobe" ;; esac

echo "=== growpart itself fails: the guard still catches it ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 2
export CZ_TEST_GROWPART_FAIL=1
run
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc despite growpart failing"
case "$out" in *"growpart exited 1"*) ok "reports growpart's failure" ;;
    *) bad "swallowed the growpart failure: $out" ;; esac
[ -e "$CZ_RESIZE_DONE" ] && bad "marked done after a failed growpart" || ok "no marker written"

echo "=== root not on partition 2: leave the disk alone ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 3
run
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $out"
case "$out" in *"unexpected partition layout"*) ok "explains the skip" ;;
    *) bad "no explanation: $out" ;; esac
case "$(calls)" in *growpart*|*resize2fs*) bad "touched the disk anyway: $(calls)" ;;
    *) ok "changed nothing" ;; esac

echo "=== disks past 2TiB are capped at the 32-bit sector limit ==="
mkfixture 9000000000 "$PART_START" "$FRESH_SIZE" 2
run
[ "$rc" = 0 ] && ok "exit 0 on an oversized disk" || bad "exit $rc: $out"
[ "$CZ_TEST_NEW_SIZE" = 4293902336 ] && ok "target size capped via 4294967295" \
    || bad "cap not applied: CZ_TEST_NEW_SIZE=$CZ_TEST_NEW_SIZE"
case "$(calls)" in *resize2fs*) ok "still grew the filesystem" ;;
    *) bad "no resize2fs on the capped path: $(calls)" ;; esac

echo "=== unit wiring: it must be able to retry after a failure ==="
grep -q '^ConditionPathExists=!/etc/cardputerzero/resize.done$' "$UNIT" \
    && ok "gated on the marker the script writes" || bad "unit is not gated on the marker"
grep -q '^ConditionFirstBoot' "$UNIT" && bad "ConditionFirstBoot is back - a failed first boot could never retry" \
    || ok "no ConditionFirstBoot directive"
grep -q '^ExecStartPost=.*disable' "$UNIT" && bad "still self-disables, which also blocks retries" \
    || ok "does not self-disable"
# The script's marker path and the unit's condition must agree, or the gate never opens.
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
