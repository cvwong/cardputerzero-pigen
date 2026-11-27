#!/bin/bash
# Tests for the deploy image filename.
#
# IMG_DATE is date-only, so every build on the same day produced the same
# filename and silently overwrote the previous image: three builds on 2026-11-27
# all wrote 2026-11-27-cardputerzero-v5-console-lite.img and only the last
# survived, which made "flash the newest one" a timestamp guess. The commit hash
# is now part of the name so different commits coexist.
#
# The naming lines are extracted from build.sh and evaluated, so this exercises
# the real code rather than a hand-copied approximation of it.
# Run: bash tests/cz-image-naming.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/../build.sh"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

NAME_LINES=$(grep -E '^export (IMG_DATE|IMG_FILENAME|ARCHIVE_FILENAME)=' "$BUILD")

name_for() { # $1 = full git hash, $2 = date; prints the .img basename
    (
        IMG_NAME=cardputerzero-v5-console
        IMG_SUFFIX=-lite
        IMG_DATE="$2"
        GIT_HASH="$1"
        unset IMG_FILENAME ARCHIVE_FILENAME
        eval "$NAME_LINES"
        printf '%s%s.img' "$IMG_FILENAME" "$IMG_SUFFIX"
    )
}
archive_for() { # $1 = full git hash, $2 = date
    (
        IMG_NAME=cardputerzero-v5-console
        IMG_DATE="$2"
        GIT_HASH="$1"
        unset IMG_FILENAME ARCHIVE_FILENAME
        eval "$NAME_LINES"
        printf '%s' "$ARCHIVE_FILENAME"
    )
}

A=a3bf5c36e265e7b5151472a3927ed62e546f0174
B=bcda727b840378cd51d7c298f43fdbf88ca2616c
D=2026-11-27

echo "=== the commit is in the filename ==="
NA=$(name_for "$A" "$D")
NB=$(name_for "$B" "$D")
printf '  %s\n  %s\n' "$NA" "$NB"
case "$NA" in *"${A:0:7}"*) ok "carries the short hash ${A:0:7}" ;;
    *) bad "no hash in $NA" ;; esac
case "$NA" in "$D"-cardputerzero-v5-console-*) ok "keeps the date and image name" ;;
    *) bad "date/name prefix lost: $NA" ;; esac
case "$NA" in *-lite.img) ok "suffix still applied last" ;;
    *) bad "suffix misplaced: $NA" ;; esac

echo "=== the collision that motivated this ==="
[ "$NA" != "$NB" ] && ok "two commits on the SAME date give different filenames" \
    || bad "same-date builds still collide: $NA"
[ "$(name_for "$A" "$D")" = "$NA" ] && ok "same commit is idempotent - a rebuild replaces only its own output" \
    || bad "same commit produced a different name"
[ "$(name_for "$A" 2026-11-28)" != "$NA" ] && ok "a different date still distinguishes too" \
    || bad "date no longer part of the name"

echo "=== the archive name follows ==="
AA=$(archive_for "$A" "$D"); AB=$(archive_for "$B" "$D")
case "$AA" in *"${A:0:7}"*) ok "archive carries the hash: $AA" ;;
    *) bad "archive has no hash: $AA" ;; esac
[ "$AA" != "$AB" ] && ok "archives do not collide either" || bad "archives collide: $AA"

echo "=== GIT_HASH must exist before the filename is built ==="
# It used to be exported ~35 lines below IMG_FILENAME, so referencing it there
# would have expanded to an empty string and silently produced a trailing dash.
GL=$(grep -n '^export GIT_HASH=' "$BUILD" | head -1 | cut -d: -f1)
FL=$(grep -n '^export IMG_FILENAME=' "$BUILD" | head -1 | cut -d: -f1)
if [ -n "$GL" ] && [ -n "$FL" ] && [ "$GL" -lt "$FL" ]; then
    ok "GIT_HASH at line $GL precedes IMG_FILENAME at $FL"
else
    bad "ordering wrong: GIT_HASH=$GL IMG_FILENAME=$FL - the hash would expand empty"
fi
[ "$(grep -c '^export GIT_HASH=' "$BUILD")" = 1 ] && ok "exported exactly once" \
    || bad "GIT_HASH exported $(grep -c '^export GIT_HASH=' "$BUILD") times"
case "$NA" in *--) bad "empty hash left a double dash: $NA" ;;
    *) ok "no empty-hash artefact in the name" ;; esac

echo
if [ "$fail" = 0 ]; then echo "CZ-IMAGE-NAMING OK"; else echo "CZ-IMAGE-NAMING PROBLEM"; exit 1; fi
