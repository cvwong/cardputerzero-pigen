#!/bin/bash
# Unit tests for resize-root, the userspace replacement for the initramfs
# ` resize` path (resize_early + set_partuuid). That path hung on this board
# before switch_root, so 02-run.sh drops the token and this script grows the
# root filesystem from a first-boot service instead.
#
# The case a naive script gets wrong: partprobe cannot re-read a disk whose
# partition is the mounted root (EBUSY), so growing the partition without
# partx --update leaves resize2fs with nothing to grow into and it exits 0
# having done nothing. The script must fail loudly in that state rather than
# report success with a 2.6G filesystem on a 29G card.
# Run: bash tests/cz-resize-root.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CZ="$HERE/../stage2/05-cardputerzero/files/resize-root"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MOCK="$WORK/bin"; mkdir -p "$MOCK"
SYS="$WORK/sys"
export CZLOG="$WORK/calls.log"
export CZ_RESIZE_SYS="$SYS"

# Geometry of the real 29.1G card: WANT_SIZE below is the 60004352 sectors that
# resize_early left behind on the failed boot.
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
# parted rewrites the partition table, but the kernel keeps the old size until
# something issues BLKPG_RESIZE_PARTITION - so deliberately do NOT touch sysfs
# here. That gap is exactly what tests 3 and 6 are about.
cat > "$MOCK/parted" <<'EOF'
#!/bin/bash
printf 'parted %s\n' "$*" >> "$CZLOG"
printf '%s\n' "${@: -1}" > "$CZ_TARGET_END"
EOF
cat > "$MOCK/partx" <<'EOF'
#!/bin/sh
printf 'partx %s\n' "$*" >> "$CZLOG"
[ "${CZ_TEST_PARTX_FAIL:-0}" = 1 ] && exit 1
end=$(cat "$CZ_TARGET_END" 2>/dev/null) || exit 1
printf '%s' "$((end - $(cat "$CZ_START_FILE") + 1))" > "$CZ_SIZE_FILE"
EOF
cat > "$MOCK/partprobe" <<'EOF'
#!/bin/sh
printf 'partprobe %s\n' "$*" >> "$CZLOG"
# Realistic default: EBUSY, because the partition being grown is the live root.
[ "${CZ_TEST_PARTPROBE_OK:-0}" = 1 ] || exit 1
end=$(cat "$CZ_TARGET_END" 2>/dev/null) || exit 1
printf '%s' "$((end - $(cat "$CZ_START_FILE") + 1))" > "$CZ_SIZE_FILE"
EOF
printf '#!/bin/sh\nprintf "resize2fs %%s\\n" "$*" >> "$CZLOG"\n' > "$MOCK/resize2fs"
chmod +x "$MOCK"/*

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
calls() { cat "$CZLOG" 2>/dev/null; }

mkfixture() { # disk_sectors part_start part_size part_num
    rm -rf "$SYS"; mkdir -p "$SYS/block/mmcblk0/mmcblk0p2"
    printf '%s' "$1" > "$SYS/block/mmcblk0/size"
    printf '%s' "$2" > "$SYS/block/mmcblk0/mmcblk0p2/start"
    printf '%s' "$3" > "$SYS/block/mmcblk0/mmcblk0p2/size"
    printf '%s' "$4" > "$SYS/block/mmcblk0/mmcblk0p2/partition"
    export CZ_SIZE_FILE="$SYS/block/mmcblk0/mmcblk0p2/size"
    export CZ_START_FILE="$SYS/block/mmcblk0/mmcblk0p2/start"
    export CZ_TARGET_END="$WORK/target_end"
    rm -f "$CZ_TARGET_END"; : > "$CZLOG"
    unset CZ_TEST_PARTX_FAIL CZ_TEST_PARTPROBE_OK
}
run() { out=$(env PATH="$MOCK:$PATH" bash "$CZ" 2>&1); rc=$?; }

echo "=== freshly flashed card: partition 2.6G on a 29G disk ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 2
run
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $out"
case "$(calls)" in *"parted -m /dev/mmcblk0 u s resizepart 2 61069311"*)
    ok "grew the partition to disk_size-1 (61069311)" ;;
    *) bad "wrong parted call: $(calls | grep parted)" ;; esac
case "$(calls)" in *"partx --update /dev/mmcblk0"*)
    ok "re-read the table with partx (works on a mounted root)" ;;
    *) bad "never called partx --update" ;; esac
case "$(calls)" in *"resize2fs /dev/mmcblk0p2"*) ok "grew the filesystem" ;;
    *) bad "never called resize2fs: $(calls)" ;; esac
case "$out" in *"cardputerzero-resize: done"*) ok "reports done" ;;
    *) bad "no completion message: $out" ;; esac

echo "=== partition already grown, filesystem not (the state the device is in) ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$GROWN_SIZE" 2
run
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $out"
case "$(calls)" in *parted*) bad "ran parted on an already-grown partition: $(calls)" ;;
    *) ok "skipped parted - re-running it would be pointless" ;; esac
case "$out" in *"skipping parted"*) ok "says why it skipped" ;;
    *) bad "no explanation for the skip: $out" ;; esac
case "$(calls)" in *resize2fs*) ok "still grew the filesystem" ;;
    *) bad "skipped resize2fs, so the card stays at 2.6G: $(calls)" ;; esac

echo "=== kernel never learns the new size: must fail, not silently succeed ==="
mkfixture "$DISK_SECTORS" "$PART_START" "$FRESH_SIZE" 2
export CZ_TEST_PARTX_FAIL=1
run
[ "$rc" = 1 ] && ok "exit 1 instead of claiming success" || bad "exit $rc - a silent no-op resize"
case "$out" in *"kernel still reports"*) ok "names the real problem" ;;
    *) bad "no diagnostic: $out" ;; esac
case "$(calls)" in *resize2fs*) bad "called resize2fs with a stale partition size" ;;
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
case "$(calls)" in *parted*|*resize2fs*) bad "touched the disk anyway: $(calls)" ;;
    *) ok "changed nothing" ;; esac

echo "=== disks past 2TiB are capped at the 32-bit sector limit ==="
mkfixture 9000000000 "$PART_START" "$FRESH_SIZE" 2
run
case "$(calls)" in *"resizepart 2 4294967295"*) ok "capped TARGET_END at 4294967295" ;;
    *) bad "no cap applied: $(calls | grep parted)" ;; esac

echo
if [ "$fail" = 0 ]; then echo "CZ-RESIZE-ROOT OK"; else echo "CZ-RESIZE-ROOT PROBLEM"; exit 1; fi
