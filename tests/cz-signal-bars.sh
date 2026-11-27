#!/bin/bash
# Unit test for cz-signal.sh: the WiFi bar scale shared by the menu headers
# (cz-theme.sh title_row_sig) and `cz-wifi signal`. Every expected value below
# is written out literally rather than derived from the implementation's own
# arithmetic, so a changed threshold cannot quietly redefine the test.
# Run: bash tests/cz-signal-bars.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FILES="$HERE/../stage2/06-cpz-features/files"
SIG="$FILES/cz-signal.sh"
THEME="$FILES/cz-theme.sh"
WIFI="$FILES/cz-wifi"
INSTALL="$HERE/../stage2/06-cpz-features/01-run.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"
        else printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fail=1; fi; }

[ -r "$SIG" ] || { echo "missing $SIG"; exit 1; }

# write_wireless <iface> <level> <quality> — a two-header-line file plus one
# interface row, shaped exactly like the kernel's.
write_wireless() {
    printf '%s\n' \
      'Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE' \
      ' face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22' \
      " $1: 0000   $3.  $2.  -256        0      0      0      0      7        0" > "$WORK/w"
}
# bars <iface> <level> <quality> — sig_bars in a fresh shell, so no state leaks
# between cases and CZ_WIRELESS is the only input.
bars() { write_wireless "$1" "$2" "$3"; CZ_WIRELESS="$WORK/w" bash -c ". '$SIG'; sig_bars"; }

echo "=== dBm -> bars, both sides of every threshold ==="
eq "-40 dBm is 4 bars"  '||||' "$(bars wlan1 -40 70)"
eq "-50 dBm is 4 bars"  '||||' "$(bars wlan1 -50 60)"
eq "-51 dBm is 3 bars"  '|||.' "$(bars wlan1 -51 59)"
eq "-59 dBm is 3 bars"  '|||.' "$(bars wlan1 -59 51)"
eq "-60 dBm is 3 bars"  '|||.' "$(bars wlan1 -60 50)"
eq "-61 dBm is 2 bars"  '||..' "$(bars wlan1 -61 49)"
eq "-69 dBm is 2 bars"  '||..' "$(bars wlan1 -69 41)"
eq "-70 dBm is 2 bars"  '||..' "$(bars wlan1 -70 40)"
eq "-71 dBm is 1 bar"   '|...' "$(bars wlan1 -71 39)"
eq "-79 dBm is 1 bar"   '|...' "$(bars wlan1 -79 31)"
eq "-80 dBm is 1 bar"   '|...' "$(bars wlan1 -80 30)"
eq "-81 dBm is 0 bars"  '....' "$(bars wlan1 -81 29)"
eq "-95 dBm is 0 bars"  '....' "$(bars wlan1 -95 15)"

echo
echo "=== the field is all-or-nothing: 4 columns, or nothing ==="
prop=0
for d in -30 -45 -55 -65 -75 -85 -99; do
    b=$(bars wlan1 "$d" 50)
    [ "${#b}" -eq 4 ] || { bad "$d dBm gave a ${#b}-char field: [$b]"; prop=1; }
    case "$b" in *[!|.]*|'') bad "$d dBm gave an off-alphabet field: [$b]"; prop=1 ;; esac
done
[ "$prop" = 0 ] && ok "every reading is exactly 4 chars of | and ."

echo
echo "=== no link means no bars at all, not a zero-filled field ==="
printf '%s\n' \
  'Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE' \
  ' face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22' > "$WORK/empty"
eq "headers only (nothing associated)" '' "$(CZ_WIRELESS="$WORK/empty" bash -c ". '$SIG'; sig_bars")"
eq "file absent"                       '' "$(CZ_WIRELESS="$WORK/nope"  bash -c ". '$SIG'; sig_bars")"

echo
echo "=== drivers that report quality instead of dBm ==="
# A positive level means IW_QUAL_DBM is unset, so the 0-100 link quality is the
# only usable number. Without this branch a USB dongle would show no bars while
# happily connected.
eq "quality 80 is 4 bars"  '||||' "$(bars wlan2 60 80)"
eq "quality 50 is 3 bars"  '|||.' "$(bars wlan2 40 50)"
eq "quality 25 is 2 bars"  '||..' "$(bars wlan2 20 25)"
eq "quality 10 is 1 bar"   '|...' "$(bars wlan2 10 10)"

echo
echo "=== the interface name must not matter ==="
# The CardputerZero associates on wlan1, not wlan0, and a USB dongle is wlan2.
for i in wlan0 wlan1 wlan2 wlp3s0; do
    eq "$i reads the same" '|||.' "$(bars "$i" -55 55)"
done
# Strip comments first: the file explains *why* wlan0 must not be hardcoded and
# therefore mentions it in prose, which a plain grep would flag as the defect.
grep -v '^[[:space:]]*#' "$SIG" | grep -q 'wlan0' \
    && bad "cz-signal.sh hardcodes wlan0 in code" \
    || ok "cz-signal.sh hardcodes no interface name"

echo
echo "=== several interfaces: the first listed wins ==="
# Matches how cz-wifi already picks IFACE (first wifi device, exit), so one
# convention covers both. Registration order, not signal order.
{ write_wireless wlan0 -75 35
  printf ' wlan1: 0000   65.  -45.  -256        0      0      0      0      7        0\n' >> "$WORK/w"; }
eq "first associated interface is used" '|...' \
    "$(CZ_WIRELESS="$WORK/w" bash -c ". '$SIG'; sig_bars")"

echo
echo "=== wiring: the theme and cz-wifi both consume this one scale ==="
grep -q 'CZ_SIGNAL=.*cz-signal.sh' "$THEME" && ok "cz-theme.sh locates cz-signal.sh" \
    || bad "cz-theme.sh does not resolve cz-signal.sh"
grep -q '^\s*\. "\$CZ_SIGNAL"' "$THEME" && ok "cz-theme.sh sources cz-signal.sh" \
    || bad "cz-theme.sh does not source cz-signal.sh"
grep -q 'CZ_SIGNAL=.*cz-signal.sh' "$WIFI" && ok "cz-wifi locates cz-signal.sh" \
    || bad "cz-wifi does not resolve cz-signal.sh"
grep -q 'sig_bars' "$WIFI" && ok "cz-wifi prints bars via sig_bars" \
    || bad "cz-wifi no longer calls sig_bars"
# The retired 5-bar '#' scale must not survive anywhere: two scales on one
# device is exactly the drift this shared file exists to prevent.
grep -q "printf '#'" "$WIFI" && bad "cz-wifi still prints the old '#' bars" \
    || ok "cz-wifi no longer prints the old '#' bars"
[ "$(grep -c 'sig_bars()' "$SIG")" = 1 ] && ok "sig_bars is defined once" \
    || bad "sig_bars is defined more than once"

echo
echo "=== headers keep their title row, dialogs keep theirs ==="
# hdr and hdr_lite are the menu pages; ask() is a modal question and stays
# centred without bars.
for fn in hdr hdr_lite; do
    awk "/^$fn\(\) \{/,/^\}/" "$THEME" | grep -q 'title_row_sig "\$1"' \
        && ok "$fn renders its title through title_row_sig" \
        || bad "$fn does not use title_row_sig"
done
awk '/^ask\(\) \{/,/^\}/' "$THEME" | grep -q 'title_row "CONFIRM"' \
    && ok "ask still centres CONFIRM with no bars" \
    || bad "ask lost its centred title_row"
# title_row_sig must reserve the field even when it is empty, or the title
# shifts sideways when the radio comes up.
awk '/^title_row_sig\(\) \{/,/^\}/' "$THEME" | grep -q '51 - 1 - ${#t} - 4 - 1' \
    && ok "title_row_sig reserves a fixed 4-column field" \
    || bad "title_row_sig does not reserve a fixed-width field"

echo
echo "=== install wiring ==="
grep -q 'install -D -m 0644 files/cz-signal.sh  *"${ROOTFS_DIR}/usr/local/lib/cz-signal.sh"' "$INSTALL" \
    && ok "01-run.sh installs cz-signal.sh to /usr/local/lib" \
    || bad "01-run.sh does not install cz-signal.sh next to cz-theme.sh"

echo
if [ "$fail" = 0 ]; then echo "CZ-SIGNAL-BARS OK"; else echo "CZ-SIGNAL-BARS PROBLEM"; exit 1; fi
