#!/bin/bash
# Tests for export-image/prerun.sh's stale-working-image cleanup.
#
# prerun.sh only ever removed the *current* image name, so every build with a
# different date or commit left its ~3 GB working copy behind. Five had piled up
# by 2026-11-27 (~12 GiB) and needed a manual prune. These are working copies -
# the keepers are what 05-finalise puts in deploy/ - so the stale ones go.
#
# The loop is extracted from prerun.sh and run against a fake STAGE_WORK_DIR, so
# this exercises the real code rather than a copy of it.
# Run: bash tests/cz-export-prune.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PRERUN="$HERE/../export-image/prerun.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

# Extract the cleanup loop verbatim.
LOOP=$(awk '/^for old in "\$\{STAGE_WORK_DIR\}"/,/^done$/' "$PRERUN")
[ -n "$LOOP" ] || { echo "FAIL: could not extract the cleanup loop from prerun.sh"; exit 1; }

STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/losetup" <<'EOF'
#!/bin/sh
# Emulate `losetup -a`: report the file named in CZ_TEST_ATTACHED, if any.
[ -n "${CZ_TEST_ATTACHED:-}" ] && printf '/dev/loop9: []: (%s)\n' "$CZ_TEST_ATTACHED"
exit 0
EOF
chmod +x "$STUB/losetup"

NAME=cardputerzero-v5-console
S="$WORK/export-image"

mkimg() { # $1 = basename without extension
    : > "$S/$1.img"
    : > "$S/$1.info"
    : > "$S/$1.bmap"
    : > "$S/$1.sbom"
}
setup() {
    rm -rf "$S"; mkdir -p "$S"
    mkimg "2026-11-23-${NAME}-lite"
    mkimg "2026-11-26-${NAME}-lite"
    mkimg "2026-11-27-${NAME}-bcda727-lite"     # hash-named, older commit
    mkimg "2026-11-27-${NAME}-a3bf5c3-lite"     # the current one
    : > "$S/unrelated-tool.img"                 # must survive
    : > "$S/notes.txt"                          # must survive
    unset CZ_TEST_ATTACHED
}
run_loop() {
    (
        STAGE_WORK_DIR="$S"
        IMG_NAME="$NAME"
        IMG_SUFFIX=-lite
        IMG_FILE="$S/2026-11-27-${NAME}-a3bf5c3-lite.img"
        PATH="$STUB:$PATH"
        eval "$LOOP"
    )
}
gone() { [ ! -e "$S/$1" ]; }
kept() { [ -e "$S/$1" ]; }

echo "=== stale working images are removed, across dates and hashes ==="
setup; run_loop >/dev/null
gone "2026-11-23-${NAME}-lite.img" && ok "old date removed" || bad "old date survived"
gone "2026-11-26-${NAME}-lite.img" && ok "another old date removed" || bad "Nov 26 survived"
gone "2026-11-27-${NAME}-bcda727-lite.img" && ok "same date, older commit removed" \
    || bad "older-commit image survived - the hash naming would still accumulate"

echo "=== the current image and unrelated files survive ==="
kept "2026-11-27-${NAME}-a3bf5c3-lite.img" && ok "current image kept" || bad "CURRENT IMAGE DELETED"
kept "unrelated-tool.img" && ok "unrelated .img kept (matched on IMG_NAME, not *.img)" \
    || bad "unrelated .img was deleted"
kept "notes.txt" && ok "non-image file kept" || bad "notes.txt deleted"

echo "=== sidecar files go with their image ==="
for e in info bmap sbom; do
    gone "2026-11-23-${NAME}-lite.$e" && ok "old .$e removed" || bad "old .$e left behind"
done
kept "2026-11-27-${NAME}-a3bf5c3-lite.info" && ok "current .info kept" || bad "current .info deleted"

echo "=== an image still attached to a loop device is skipped ==="
setup
export CZ_TEST_ATTACHED="$S/2026-11-26-${NAME}-lite.img"
run_loop >/dev/null
kept "2026-11-26-${NAME}-lite.img" && ok "attached image kept" || bad "DELETED an image in use by a loop device"
gone "2026-11-23-${NAME}-lite.img" && ok "unattached ones still pruned" || bad "pruning stopped entirely"
unset CZ_TEST_ATTACHED

echo "=== idempotent: a second pass is a no-op ==="
setup; run_loop >/dev/null
before=$(ls -1 "$S" | sort)
run_loop >/dev/null
after=$(ls -1 "$S" | sort)
[ "$before" = "$after" ] && ok "second pass changed nothing" || bad "second pass differed"

echo
if [ "$fail" = 0 ]; then echo "CZ-EXPORT-PRUNE OK"; else echo "CZ-EXPORT-PRUNE PROBLEM"; exit 1; fi
