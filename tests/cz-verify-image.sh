#!/bin/bash
# Tests for tools/verify-image.sh, the script CI runs on every built image
# (.github/workflows/build.yml:180 and :359).
#
# The script itself mounts the image with a loop device and so needs root, but
# the parts that have actually broken are all extractable and testable without
# it: the debugfs size parsing, and drift between its required-package list and
# what the build declares. Every assertion here evaluates code taken from the
# script rather than a copy of it.
#
# Two real defects this guards:
#   1. debugfs stat prints two lines containing "Size:" (the inode line and a
#      trailing "Fragment: Address: 0 Number: 0 Size: 0"). Taking field 2 of both
#      concatenated them, so every module reported "(0\nAddress: bytes)" and a
#      0-byte module was indistinguishable from a healthy one.
#   2. The required-package list drifted from the build: applaunch/fastfetch/
#      cmatrix were asserted but installed by no live stage, so CI failed on every
#      image, for both variants.
# Run: bash tests/cz-verify-image.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
VI="$ROOT/tools/verify-image.sh"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$VI" ] || { echo "FAIL: $VI missing"; exit 1; }

# Pull the real awk program out of the script so the test cannot drift from it.
SIZE_AWK=$(sed -n "s/.*awk '\(.*\)')\$/\1/p" "$VI" | grep -F '/Size:' | head -1)
if [ -z "$SIZE_AWK" ]; then echo "FAIL: could not extract the Size: awk program"; exit 1; fi

size_of() { printf '%s\n' "$1" | awk "$SIZE_AWK"; }

# Realistic debugfs stat output for a healthy module: note BOTH "Size:" lines.
HEALTHY='Inode: 131844   Type: regular    Mode:  0644   Flags: 0x80000
Generation: 2a1b3c4d    Version: 0x00000000:00000001
User:     0   Group:     0   Project:     0   Size: 51234
File ACL: 0    Directory ACL: 0
Links: 1   Blockcount: 104
Fragment:  Address: 0    Number: 0    Size: 0
 ctime: 0x6926abcd -- Thu Nov 27 20:35:00 2026'

echo "=== debugfs size extraction ==="
[ "$(size_of "$HEALTHY")" = "51234" ] && ok "reads the inode size past the Fragment line" \
    || bad "got '$(size_of "$HEALTHY")', expected 51234"
# The exact garbage the buggy version produced.
case "$(size_of "$HEALTHY")" in *Address*|*$'\n'*) bad "output still contains the Fragment line's fields" ;;
    *) ok "output is a single clean number" ;; esac
[ -z "$(size_of 'stat: Extent not found')" ] && ok "missing file yields empty, so fail still fires" \
    || bad "missing file yielded '$(size_of 'stat: Extent not found')' - would be reported as present"
[ "$(size_of 'User:     0   Group:     0   Size: 0
Fragment:  Address: 0    Size: 0')" = "0" ] && ok "a genuine 0-byte module still reads as 0, not missing" \
    || bad "zero-size handling wrong"
# The regression itself: the old pipeline must not be back.
grep -q "grep \"Size:\" | awk '{print \$2}'" "$VI" && bad "the buggy 'grep Size: | awk {print \$2}' is back" \
    || ok "the buggy size pipeline is gone"

echo "=== required packages match what the build actually declares ==="
# Declared packages come from the live packages files only; .orig backups are
# inert (pi-gen's sub-stage glob runs *-run.sh, and packages files likewise), so
# including them is how fastfetch/cmatrix went unnoticed.
DECLARED=$(grep -hv '^[[:space:]]*#' $(find "$ROOT"/stage0 "$ROOT"/stage1 "$ROOT"/stage2 \
    -name '*packages*' ! -name '*.orig' 2>/dev/null) 2>/dev/null \
    | tr -s ' \t' '\n' | grep -v '^$' | sort -u)
[ -n "$DECLARED" ] || { bad "could not read any packages file - test is vacuous"; }
eval "$(sed -n '/^REQUIRED_PACKAGES=(/,/)$/p' "$VI")"
[ "${#REQUIRED_PACKAGES[@]}" -gt 0 ] && ok "REQUIRED_PACKAGES has ${#REQUIRED_PACKAGES[@]} entries" \
    || bad "REQUIRED_PACKAGES is empty"
for p in "${REQUIRED_PACKAGES[@]}"; do
    if printf '%s\n' "$DECLARED" | grep -qx -- "$p"; then
        ok "$p is declared by a live packages file"
    else
        bad "$p is asserted by verify-image.sh but no live packages file declares it - CI would fail on every build"
    fi
done
# The retired trio must not come back.
for p in applaunch fastfetch cmatrix; do
    case " ${REQUIRED_PACKAGES[*]} " in *" $p "*) bad "$p is back in REQUIRED_PACKAGES (retired desktop package)" ;;
        *) ok "$p correctly not required" ;; esac
done

echo "=== required kernel modules ==="
eval "$(sed -n '/^REQUIRED_MODULES=(/,/^)/p' "$VI")"
[ "${#REQUIRED_MODULES[@]}" -gt 0 ] && ok "${#REQUIRED_MODULES[@]} modules required" \
    || bad "REQUIRED_MODULES is empty"
for m in "${REQUIRED_MODULES[@]}"; do
    case "$m" in *.ko) ;; *) bad "module entry does not look like a .ko: $m" ;; esac
done
ok "every module entry ends in .ko"

echo "=== retired desktop assertions are gone ==="
for pat in 'APPLaunch binary MISSING' 'APPLaunch user service MISSING' \
           'fastfetch NOT installed' 'cmatrix NOT installed' 'applaunch package NOT installed' \
           'splash.bmp MISSING'; do
    grep -qF "$pat" "$VI" && bad "stale assertion still present: $pat" || ok "no '$pat'"
done
# The negative checks are deliberately kept.
grep -q 'APPLaunch user service not enabled' "$VI" && ok "keeps the 'not enabled' guard" \
    || bad "the 'not enabled' guard was dropped too"

echo "=== fail() actually drives the exit code ==="
# Silence pass/fail's own output, or it is captured along with $ERRORS and the
# comparison never sees a bare number.
out=$(eval "$(sed -n '/^fail()/p;/^pass()/p' "$VI")"
      ERRORS=0
      pass ok   >/dev/null
      fail bad1 >/dev/null
      fail bad2 >/dev/null
      echo "$ERRORS")
[ "$out" = 2 ] && ok "two fail() calls set ERRORS=2 (pass() does not)" || bad "ERRORS accounting wrong: got [$out]"
grep -q 'if \[ \$ERRORS -eq 0 \]' "$VI" && grep -q 'exit 1' "$VI" \
    && ok "non-zero ERRORS exits 1, so CI sees the failure" \
    || bad "exit status does not depend on ERRORS"

echo "=== the dtbo checked is the one config.txt actually loads ==="
# Third real defect this guards: the dtbo check scanned CARDPUTERZERO_OVERLAYS
# for ANY .dtbo that existed and broke at the first hit, independently of the
# overlay name already resolved from config.txt. An image ships both the v3 and
# v5 overlays, so a missing v5 - the one the firmware loads, and the one the
# keypad/LCD/battery depend on - passed verification on the strength of the
# unrelated v3 file.
DTBO_BLOCK=$(sed -n '/^# Check the dtbo for the overlay/,/^fi$/p' "$VI")
if [ -z "$DTBO_BLOCK" ]; then echo "FAIL: could not extract the dtbo block"; exit 1; fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RESULTS="$WORK/results"
W1="$WORK/both"; W2="$WORK/v3only"; W3="$WORK/v3only-named"
# Sizes match the real image so a wrong-file report is detectable by size too.
mk_boot() { # mk_boot <dir> <has-v3:yes|no> <has-v5:yes|no>
    mkdir -p "$1/boot/overlays"
    [ "$2" = yes ] && head -c 7208 /dev/zero > "$1/boot/overlays/cardputerzero-v3-overlay.dtbo"
    [ "$3" = yes ] && head -c 9550 /dev/zero > "$1/boot/overlays/cardputerzero-v5-overlay.dtbo"
    return 0
}
# Run the script's own block with stub pass/fail, as the ERRORS test above does.
# CARDPUTERZERO_OVERLAYS is extracted from the script too, so a reverted
# scan-any-dtbo block executes here and is caught on its behaviour rather than
# merely crashing on an unbound array under set -u.
run_dtbo() { # run_dtbo <overlay name from config.txt> <tmpdir>
    : > "$RESULTS"
    ( TMPDIR="$2"; FOUND_CARDPUTERZERO_OVERLAY="$1"; ERRORS=0
      eval "$(sed -n '/^CARDPUTERZERO_OVERLAYS=(/,/^)/p' "$VI")"
      pass() { printf 'PASS %s\n' "$1" >> "$RESULTS"; }
      fail() { printf 'FAIL %s\n' "$1" >> "$RESULTS"; ERRORS=$((ERRORS+1)); }
      eval "$DTBO_BLOCK"
      printf 'ERRORS %s\n' "$ERRORS" >> "$RESULTS" ) >/dev/null 2>&1
}

# What the real image looks like: config.txt loads v5, both dtbos shipped.
mk_boot "$W1" yes yes
run_dtbo "cardputerzero-v5-overlay" "$W1"
grep -q 'ERRORS 0' "$RESULTS" && ok "v5 loaded and v5 present passes" \
    || bad "healthy v5 image reported an error: $(tr '\n' ';' < "$RESULTS")"
grep -qF 'cardputerzero-v5-overlay.dtbo exists (9550 bytes)' "$RESULTS" \
    && ok "reports the v5 dtbo that is loaded, not the unrelated v3" \
    || bad "did not report the loaded v5 dtbo: $(tr '\n' ';' < "$RESULTS")"

# The defect itself: config.txt loads v5, only v3 shipped.
mk_boot "$W2" yes no
run_dtbo "cardputerzero-v5-overlay" "$W2"
grep -q 'ERRORS 1' "$RESULTS" \
    && ok "v5 loaded but v5 MISSING fails (the old any-dtbo scan passed here)" \
    || bad "a missing loaded overlay did not fail: $(tr '\n' ';' < "$RESULTS")"
grep -qF 'config.txt loads cardputerzero-v5-overlay but' "$RESULTS" \
    && ok "the failure names the overlay config.txt loads" \
    || bad "failure does not name the loaded overlay: $(tr '\n' ';' < "$RESULTS")"
grep -qF 'cardputerzero-v3-overlay.dtbo exists' "$RESULTS" \
    && bad "still credits the unrelated v3 dtbo as satisfying the check" \
    || ok "the unrelated v3 dtbo no longer satisfies the check"

# The v3 board must still verify when v3 is what config.txt loads.
mk_boot "$W3" yes no
run_dtbo "cardputerzero-v3-overlay" "$W3"
grep -q 'ERRORS 0' "$RESULTS" && ok "v3 loaded and v3 present still passes" \
    || bad "a healthy v3 image now fails: $(tr '\n' ';' < "$RESULTS")"

# No overlay named in config.txt already fails upstream; this block must not
# double-count the same root cause.
run_dtbo "" "$W1"
grep -q 'ERRORS 0' "$RESULTS" \
    && ok "an unnamed overlay adds no second failure for the same cause" \
    || bad "unnamed overlay double-counted: $(tr '\n' ';' < "$RESULTS")"

# The old independent scan must not come back.
grep -q 'FOUND_CARDPUTERZERO_DTBO' "$VI" \
    && bad "the old scan-any-dtbo variable is back in verify-image.sh" \
    || ok "the old scan-any-dtbo loop is gone"

echo
if [ "$fail" = 0 ]; then echo "CZ-VERIFY-IMAGE OK"; else echo "CZ-VERIFY-IMAGE PROBLEM"; exit 1; fi
