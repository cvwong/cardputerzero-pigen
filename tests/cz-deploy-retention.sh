#!/bin/bash
# Test for the deploy/ retention block in export-image/05-finalise/01-run.sh.
#
# Retention deletes build artifacts, so the assertions here are about what it
# must NOT touch as much as what it must remove: the just-built set, sets inside
# the keep count, anything not matching IMG_NAME, and anything still attached to
# a loop device. The real block is extracted from the stage script and evaluated
# against synthetic deploy directories, so the test cannot drift from the code.
# Run: bash tests/cz-deploy-retention.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FIN="$HERE/../export-image/05-finalise/01-run.sh"
WORK=$(mktemp -d)
STUB="$WORK/bin"
mkdir -p "$STUB"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$FIN" ] || { echo "FAIL: $FIN missing"; exit 1; }

# The retention block runs from its marker to end of file.
BLOCK=$(sed -n '/^# --- deploy\/ retention ---/,$p' "$FIN")
if [ -z "$BLOCK" ]; then echo "FAIL: could not extract the retention block"; exit 1; fi
bash -n <(printf '%s\n' "$BLOCK") 2>/dev/null || { echo "FAIL: extracted block does not parse"; exit 1; }

# losetup is stubbed so the "still attached" branch is exercisable. The test
# points LOSETUP_OUTPUT at a file listing whatever should look loop-backed.
cat > "$STUB/losetup" <<'EOF'
#!/bin/bash
cat "$LOSETUP_OUTPUT" 2>/dev/null
EOF
chmod +x "$STUB/losetup"
LOSETUP_OUTPUT="$WORK/losetup.txt"
: > "$LOSETUP_OUTPUT"
export LOSETUP_OUTPUT PATH="$STUB:$PATH"

IMG_NAME="cardputerzero-v5-console"

# mkset <dir> <stem> <mtime> — a full artifact set, all members equally old.
mkset() {
    local d="$1" s="$2" t="$3"
    : > "$d/$s.img"; : > "$d/$s.bmap"; : > "$d/$s.info"
    touch -d "$t" "$d/$s.img" "$d/$s.bmap" "$d/$s.info"
}

run_retention() { # run_retention <deploy-dir> <keep> -> prints the block's stdout
    ( DEPLOY_DIR="$1"; DEPLOY_KEEP="$2"; IMG_NAME="$IMG_NAME"
      eval "$BLOCK" ) 2>&1
}

stems_left() { # stems_left <deploy-dir> -> sorted list of remaining .img stems
    local d="$1" b
    for f in "$d"/*.img; do
        [ -e "$f" ] || continue
        b=$(basename "$f"); printf '%s\n' "${b%.img}"
    done | sort
}

echo "=== retention must run AFTER the image is copied to deploy/ ==="
copy_line=$(grep -n 'cp "\$INFO_FILE" "\$DEPLOY_DIR/"' "$FIN" | tail -1 | cut -d: -f1)
mark_line=$(grep -n '^# --- deploy/ retention ---' "$FIN" | cut -d: -f1)
if [ -n "$copy_line" ] && [ -n "$mark_line" ] && [ "$mark_line" -gt "$copy_line" ]; then
    ok "retention follows the deploy copy (line $mark_line > $copy_line), so the new image counts as a keeper"
else
    bad "retention is not after the deploy copy (copy=$copy_line retention=$mark_line)"
fi

echo
echo "=== four sets, keep three: the oldest goes, siblings and all ==="
D="$WORK/four"; mkdir -p "$D"
mkset "$D" "2026-11-25-${IMG_NAME}-aaa1111-lite" "2026-11-25 10:00:00"
mkset "$D" "2026-11-26-${IMG_NAME}-bbb2222-lite" "2026-11-26 10:00:00"
mkset "$D" "2026-11-27-${IMG_NAME}-ccc3333-lite" "2026-11-27 10:00:00"
mkset "$D" "2026-11-28-${IMG_NAME}-ddd4444-lite" "2026-11-28 10:00:00"
out=$(run_retention "$D" 3)
left=$(stems_left "$D")
[ "$(printf '%s\n' "$left" | wc -l)" = 3 ] && ok "exactly three sets remain" \
    || bad "expected 3 sets, got $(printf '%s\n' "$left" | wc -l): $(echo "$left" | tr '\n' ' ')"
case "$left" in *"aaa1111"*) bad "the oldest set survived" ;; *) ok "the oldest set was removed" ;; esac
case "$left" in *ddd4444*) ok "the newest (just-built) set was kept" ;; *) bad "the newest set was removed" ;; esac
[ -e "$D/2026-11-25-${IMG_NAME}-aaa1111-lite.info" ] && bad "the removed set's .info was orphaned" \
    || ok "the removed set's .info went with it"
[ -e "$D/2026-11-25-${IMG_NAME}-aaa1111-lite.bmap" ] && bad "the removed set's .bmap was orphaned" \
    || ok "the removed set's .bmap went with it"
printf '%s\n' "$out" | grep -q 'Removing old deployed image' && ok "reports what it removes" \
    || bad "removed a set silently"

echo
echo "=== boundary: exactly DEPLOY_KEEP sets removes nothing ==="
D="$WORK/three"; mkdir -p "$D"
mkset "$D" "2026-11-26-${IMG_NAME}-bbb2222-lite" "2026-11-26 10:00:00"
mkset "$D" "2026-11-27-${IMG_NAME}-ccc3333-lite" "2026-11-27 10:00:00"
mkset "$D" "2026-11-28-${IMG_NAME}-ddd4444-lite" "2026-11-28 10:00:00"
run_retention "$D" 3 >/dev/null
[ "$(stems_left "$D" | wc -l)" = 3 ] && ok "all three kept at the boundary" \
    || bad "removed a set when count equalled DEPLOY_KEEP"

echo
echo "=== five sets, keep two: three oldest go ==="
D="$WORK/five"; mkdir -p "$D"
for i in 1 2 3 4 5; do mkset "$D" "2026-11-2${i}-${IMG_NAME}-h${i}h${i}h${i}h-lite" "2026-11-2${i} 10:00:00"; done
run_retention "$D" 2 >/dev/null
left=$(stems_left "$D")
[ "$(printf '%s\n' "$left" | wc -l)" = 2 ] && ok "two sets remain" || bad "expected 2, got: $(echo "$left" | tr '\n' ' ')"
case "$left" in *h4h4h4h*h5h5h5h*|*h5h5h5h*h4h4h4h*) ok "the two newest remain" ;;
    *) bad "wrong survivors: $(echo "$left" | tr '\n' ' ')" ;; esac

echo
echo "=== DEPLOY_KEEP=0 disables retention entirely ==="
D="$WORK/off"; mkdir -p "$D"
for i in 1 2 3 4 5; do mkset "$D" "2026-11-2${i}-${IMG_NAME}-h${i}h${i}h${i}h-lite" "2026-11-2${i} 10:00:00"; done
run_retention "$D" 0 >/dev/null
[ "$(stems_left "$D" | wc -l)" = 5 ] && ok "nothing removed with DEPLOY_KEEP=0" \
    || bad "DEPLOY_KEEP=0 still deleted something"

echo
echo "=== ranking is by mtime, not by filename ==="
# A set whose name sorts first but whose mtime is newest must survive.
D="$WORK/mtime"; mkdir -p "$D"
mkset "$D" "2026-01-01-${IMG_NAME}-zzz9999-lite" "2026-11-28 10:00:00"
mkset "$D" "2026-11-27-${IMG_NAME}-mmm5555-lite" "2026-11-20 10:00:00"
mkset "$D" "2026-11-26-${IMG_NAME}-nnn6666-lite" "2026-11-10 10:00:00"
run_retention "$D" 1 >/dev/null
left=$(stems_left "$D")
case "$left" in *zzz9999*) ok "the newest-by-mtime set survived despite sorting first by name" ;;
    *) bad "ranked by name, not mtime; survivors: $(echo "$left" | tr '\n' ' ')" ;; esac
[ "$(printf '%s\n' "$left" | wc -l)" = 1 ] && ok "only one set left" || bad "left $(printf '%s\n' "$left" | wc -l)"

echo
echo "=== files outside IMG_NAME are never candidates ==="
D="$WORK/other"; mkdir -p "$D"
mkset "$D" "2026-11-25-${IMG_NAME}-aaa1111-lite" "2026-11-25 10:00:00"
mkset "$D" "2026-11-26-${IMG_NAME}-bbb2222-lite" "2026-11-26 10:00:00"
mkset "$D" "2026-11-27-${IMG_NAME}-ccc3333-lite" "2026-11-27 10:00:00"
mkset "$D" "2026-11-28-${IMG_NAME}-ddd4444-lite" "2026-11-28 10:00:00"
: > "$D/someone-elses-backup.img"; touch -d "2020-01-01 10:00:00" "$D/someone-elses-backup.img"
: > "$D/notes.txt";                     touch -d "2020-01-01 10:00:00" "$D/notes.txt"
run_retention "$D" 3 >/dev/null
[ -e "$D/someone-elses-backup.img" ] && ok "an unrelated .img was not touched" \
    || bad "deleted an unrelated .img"
[ -e "$D/notes.txt" ] && ok "an unrelated file was not touched" || bad "deleted an unrelated file"

echo
echo "=== a loop-backed set is skipped, not deleted ==="
D="$WORK/loop"; mkdir -p "$D"
mkset "$D" "2026-11-25-${IMG_NAME}-aaa1111-lite" "2026-11-25 10:00:00"
mkset "$D" "2026-11-26-${IMG_NAME}-bbb2222-lite" "2026-11-26 10:00:00"
mkset "$D" "2026-11-27-${IMG_NAME}-ccc3333-lite" "2026-11-27 10:00:00"
mkset "$D" "2026-11-28-${IMG_NAME}-ddd4444-lite" "2026-11-28 10:00:00"
printf '/dev/loop0: [0]:1234 (%s/2026-11-25-%s-aaa1111-lite.img)\n' "$D" "$IMG_NAME" > "$LOSETUP_OUTPUT"
out=$(run_retention "$D" 3)
[ -e "$D/2026-11-25-${IMG_NAME}-aaa1111-lite.img" ] \
    && ok "the loop-backed oldest set was kept" || bad "deleted a loop-backed image"
printf '%s\n' "$out" | grep -q 'still attached to a loop device' \
    && ok "says why it was kept" || bad "kept it silently"
[ "$(stems_left "$D" | wc -l)" = 4 ] && ok "nothing else was removed in its place" \
    || bad "removed a different set to make room: $(stems_left "$D" | tr '\n' ' ')"
: > "$LOSETUP_OUTPUT"

echo
echo "=== compressed archives group with their .info as one set ==="
# DEPLOY_COMPRESSION != none deploys image_<stem>.img.xz while the .info keeps
# the unprefixed stem; both must be recognised as the same set.
D="$WORK/xz"; mkdir -p "$D"
for i in 1 2 3; do
    s="2026-11-2${i}-${IMG_NAME}-c${i}c${i}c${i}c-lite"
    : > "$D/image_$s.img.xz"; : > "$D/$s.info"; : > "$D/$s.bmap"
    touch -d "2026-11-2${i} 10:00:00" "$D/image_$s.img.xz" "$D/$s.info" "$D/$s.bmap"
done
s4="2026-11-28-${IMG_NAME}-c4c4c4c4-lite"
: > "$D/image_$s4.img.xz"; : > "$D/$s4.info"; : > "$D/$s4.bmap"
touch -d "2026-11-28 10:00:00" "$D/image_$s4.img.xz" "$D/$s4.info" "$D/$s4.bmap"
run_retention "$D" 3 >/dev/null
[ -e "$D/image_2026-11-21-${IMG_NAME}-c1c1c1c1-lite.img.xz" ] \
    && bad "the oldest compressed archive survived" || ok "the oldest compressed archive was removed"
[ -e "$D/2026-11-21-${IMG_NAME}-c1c1c1c1-lite.info" ] \
    && bad "its .info was orphaned" || ok "its .info went with it"
[ -e "$D/image_$s4.img.xz" ] && ok "the newest compressed set was kept" || bad "removed the newest set"
n=$(ls -1 "$D" | wc -l)
[ "$n" = 9 ] && ok "exactly 3 sets of 3 artifacts remain ($n files)" || bad "left $n files, expected 9"

echo
echo "=== sbom artifacts are removed with their set ==="
D="$WORK/sbom"; mkdir -p "$D"
for i in 1 2 3 4; do
    s="2026-11-2${i}-${IMG_NAME}-s${i}s${i}s${i}s-lite"
    mkset "$D" "$s" "2026-11-2${i} 10:00:00"
    : > "$D/$s.sbom.xz"; touch -d "2026-11-2${i} 10:00:00" "$D/$s.sbom.xz"
done
run_retention "$D" 3 >/dev/null
[ -e "$D/2026-11-21-${IMG_NAME}-s1s1s1s1-lite.sbom.xz" ] \
    && bad "the removed set's .sbom.xz was orphaned" || ok ".sbom.xz removed with its set"

echo
if [ "$fail" = 0 ]; then echo "CZ-DEPLOY-RETENTION OK"; else echo "CZ-DEPLOY-RETENTION PROBLEM"; exit 1; fi
