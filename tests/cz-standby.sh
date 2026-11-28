#!/bin/bash
# Test for the idle screen-blank: cz-standby.sh plus its wiring into
# cz-menu-theme. Run: bash tests/cz-standby.sh
#
# The interesting cases are the ones that look fine by exit code alone. ENTER
# alone must NOT resume standby, but do_standby also returns 0 when stdin ends,
# so a plain "did it return" check passes for the wrong reason. Those cases
# count read(1) invocations instead, via a `read` wrapper that shadows the
# builtin and delegates to it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FILES="$HERE/../stage2/06-cpz-features/files"
SB="$FILES/cz-standby.sh"
MT="$FILES/cz-menu-theme"
THEME="$FILES/cz-theme.sh"
INSTALL="$HERE/../stage2/06-cpz-features/01-run.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"
        else printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fail=1; fi; }

for f in "$SB" "$MT" "$THEME"; do
    [ -r "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

# ---- fixtures -------------------------------------------------------------
# Two framebuffers; which index is the panel varies between real boots, so the
# tests pin it explicitly in both positions.
mk_gfx() { # mk_gfx <dir> <panel-index>
    local d="$1" p="$2" i
    mkdir -p "$d"
    for i in 0 1; do
        mkdir -p "$d/fb$i"
        if [ "$i" = "$p" ]; then echo "320,170" > "$d/fb$i/virtual_size"
        else echo "1920,1080" > "$d/fb$i/virtual_size"; fi
    done
}
mk_bl() { # mk_bl <dir> <brightness>
    mkdir -p "$1"; printf '%s\n' "$2" > "$1/brightness"; printf '100\n' > "$1/max_brightness"
}
# Fake python3: record the FBIOBLANK target and mode instead of issuing ioctls.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/python3" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$CZ_FB_DEV" "$CZ_FB_ARG" >> "$IOCTL_LOG"
EOF
chmod +x "$WORK/bin/python3"
export IOCTL_LOG="$WORK/ioctls"

echo "=== panel framebuffer is found by size, never by index ==="
mk_gfx "$WORK/gfx0" 0
eq "panel at fb0 resolves to 0" "0" \
   "$(CZ_SYS_GRAPHICS="$WORK/gfx0" bash -c ". '$SB'; cz_panel_fb")"
mk_gfx "$WORK/gfx1" 1
eq "panel at fb1 resolves to 1 (index is not stable across boots)" "1" \
   "$(CZ_SYS_GRAPHICS="$WORK/gfx1" bash -c ". '$SB'; cz_panel_fb")"
mkdir -p "$WORK/gfxnone/fb0"; echo "1920,1080" > "$WORK/gfxnone/fb0/virtual_size"
CZ_SYS_GRAPHICS="$WORK/gfxnone" bash -c ". '$SB'; cz_panel_fb" >/dev/null 2>&1 \
   && bad "cz_panel_fb succeeded with no 320x170 framebuffer" \
   || ok "cz_panel_fb fails cleanly when there is no panel"
grep -v '^[[:space:]]*#' "$SB" | grep -qE '/dev/fb[01]\b' \
   && bad "cz-standby.sh hardcodes a framebuffer index" \
   || ok "cz-standby.sh hardcodes no framebuffer index"

echo
echo "=== timeout configuration ==="
CONF="$WORK/conf"
sb() { CZ_STANDBY_CONF="$CONF" CZ_STANDBY_CHOICES="1 5 10 30" CZ_STANDBY_DEFAULT=5 \
       bash -c ". '$SB'; $1"; }
rm -f "$CONF"
eq "absent config -> default 5"      "5"    "$(sb 'cz_standby_minutes')"
eq "absent config -> 300 seconds"    "300"  "$(sb 'cz_standby_seconds')"
sb 'cz_standby_set_minutes 1'  >/dev/null; eq "set 1  -> 1 min"   "1"   "$(sb 'cz_standby_minutes')"
sb 'cz_standby_set_minutes 10' >/dev/null; eq "set 10 -> 600 s"   "600" "$(sb 'cz_standby_seconds')"
sb 'cz_standby_set_minutes 30' >/dev/null; eq "set 30 -> 30 min"  "30"  "$(sb 'cz_standby_minutes')"
sb 'cz_standby_set_minutes 7'  >/dev/null \
   && bad "an unlisted value (7) was accepted" || ok "an unlisted value (7) is rejected"
eq "rejected write left the previous value" "30" "$(sb 'cz_standby_minutes')"
printf 'garbage\n' > "$CONF"; eq "corrupt config falls back to default" "5" "$(sb 'cz_standby_minutes')"
printf '10 trailing junk\n' > "$CONF"; eq "trailing junk is stripped" "10" "$(sb 'cz_standby_minutes')"
printf '' > "$CONF"; eq "empty config falls back to default" "5" "$(sb 'cz_standby_minutes')"

echo
echo "=== blank then wake: order, backlight save/restore, ioctl modes ==="
mk_gfx "$WORK/g" 0; mk_bl "$WORK/bl" 73
: > "$IOCTL_LOG"
# One process, so the brightness saved by blank is the one wake restores - the
# real behaviour. Splitting them across two shells would prove nothing.
mid_end=$(PATH="$WORK/bin:$PATH" CZ_SYS_GRAPHICS="$WORK/g" CZ_BACKLIGHT="$WORK/bl" \
  bash -c ". '$SB'
           cz_standby_blank
           printf 'mid=%s\n' \"\$(cat '$WORK/bl/brightness')\"
           cz_standby_wake
           printf 'end=%s\n' \"\$(cat '$WORK/bl/brightness')\"" 2>/dev/null)
eq "brightness is 0 while blanked"  "mid=0"  "$(printf '%s\n' "$mid_end" | sed -n 1p)"
eq "brightness restored afterwards" "end=73" "$(printf '%s\n' "$mid_end" | sed -n 2p)"
# Assert the two ioctls explicitly rather than by a fragile path comparison.
first=$(sed -n 1p "$IOCTL_LOG"); second=$(sed -n 2p "$IOCTL_LOG")
case "$first" in */fb0\ 4) ok "first ioctl is FB_BLANK_POWERDOWN on the panel fb" ;;
    *) bad "first ioctl was [$first], expected .../fb0 4" ;; esac
case "$second" in */fb0\ 0) ok "second ioctl is VESA_NO_BLANKING on the panel fb" ;;
    *) bad "second ioctl was [$second], expected .../fb0 0" ;; esac
eq "exactly two ioctls for one blank+wake cycle" "2" "$(grep -c . "$IOCTL_LOG")"

echo
echo "=== the TAB-then-ENTER gate ==="
export CZ_THEME="$THEME" CZ_STANDBY="$SB"
export CZ_WIRELESS="$WORK/wireless"
printf 'Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE\n face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22\n wlan1: 0000   62.  -48.  -256        0      0      0      0      7        0\n' > "$CZ_WIRELESS"
n=$(grep -n '^while :; do' "$MT" | tail -1 | cut -d: -f1)
head -n $((n-1)) "$MT" > "$WORK/fn.sh"

# Harness: stub the hardware and the screen, shadow `read` to count calls.
READLOG="$WORK/reads"
gate() { # gate <escape-sequence> -> prints "<rc> <reads> <blanks> <wakes> <screens>"
    # %b, and the caller passes the escapes unevaluated: $(printf 'x\\t\\n')
    # would strip the trailing newline and the case would end on EOF instead.
    printf '%b' "$1" | bash -c '
        READLOG="'"$READLOG"'"; CALLS="'"$WORK/calls"'"
        : > "$READLOG"; : > "$CALLS"
        read() { printf x >> "$READLOG"; builtin read "$@"; }
        cz_standby_blank() { printf blank >> "$CALLS"; }
        cz_standby_wake()  { printf wake  >> "$CALLS"; }
        standby_screen()   { printf screen >> "$CALLS"; }
        TAB=$(printf "\t")
        source "'"$WORK/fn.sh"'" 2>/dev/null
        cz_standby_blank() { printf blank >> "$CALLS"; }
        cz_standby_wake()  { printf wake  >> "$CALLS"; }
        standby_screen()   { printf screen >> "$CALLS"; }
        do_standby; rc=$?
        printf "%s %s %s %s %s\n" "$rc" "$(wc -c < "$READLOG")" \
            "$(grep -o blank "$CALLS" | wc -l)" "$(grep -o wake "$CALLS" | wc -l)" \
            "$(grep -o screen "$CALLS" | wc -l)"
    '
}
# x wakes, TAB then ENTER resumes: 3 reads.
r=$(gate 'x\t\n'); eq "x,TAB,ENTER resumes" "0 3 1 1 1" "$r"
# x wakes, ENTER alone must be ignored, then TAB+ENTER resumes: 4 reads.
# If ENTER resumed, this would be 2 reads - the exit code alone cannot tell.
r=$(gate 'x\n\t\n'); eq "ENTER alone does not resume (4 reads, not 2)" "0 4 1 1 1" "$r"
# x wakes, TAB then a non-ENTER key must not resume either: 5 reads.
r=$(gate 'x\tq\t\n'); eq "TAB then a non-ENTER key does not resume" "0 5 1 1 1" "$r"
# The panel is blanked exactly once and woken exactly once per standby.
r=$(gate 'x\t\n')
eq "one blank, one wake, one notice per standby" "0 3 1 1 1" "$r"

echo
echo "=== the STAND BY notice re-blanks if the user walks away again ==="
# Regression for a bug found on hardware 2026-11-28: the notice waited on a
# blocking read, so waking it and then pressing nothing held the backlight on
# forever. Uses a real 1-second timeout and delayed keystrokes rather than a
# structural assertion, so it reproduces the reported sequence:
#   idle -> blank -> press a key -> notice -> press nothing -> must re-blank.
# With the bug this yields "0 1 1 1"; fixed it yields "0 2 2 2". Costs ~2.5 s.
CALLS2="$WORK/calls2"
gate_slow() {
    { printf 'x'; sleep 2.5; printf '\t\n'; } | bash -c '
        CALLS="'"$CALLS2"'"; : > "$CALLS"
        TAB=$(printf "\t")
        source "'"$WORK/fn.sh"'" 2>/dev/null
        cz_standby_blank()   { printf blank  >> "$CALLS"; }
        cz_standby_wake()    { printf wake   >> "$CALLS"; }
        standby_screen()     { printf screen >> "$CALLS"; }
        cz_standby_seconds() { printf 1; }
        do_standby; rc=$?
        printf "%s %s %s %s\n" "$rc" "$(grep -o blank "$CALLS" | wc -l)" \
            "$(grep -o wake "$CALLS" | wc -l)" "$(grep -o screen "$CALLS" | wc -l)"
    '
}
r=$(gate_slow)
eq "idle at the notice re-blanks, and TAB+ENTER still resumes afterwards" "0 2 2 2" "$r"

echo
echo "=== the (current) marker moves the moment a value is selected ==="
# Reported from hardware 2026-11-28: the marker stayed on the old value until
# the user left the screen, because menu() builds its label array once and
# redraws that same array on every keypress. m_timeout now has its own loop and
# re-reads the setting each redraw. Feed a selection then Back, and inspect the
# SECOND screen: the marker must already have moved.
CONF2="$WORK/conf2"
printf '5\n' > "$CONF2"
CZ_STANDBY_CONF="$CONF2" LC_ALL=C.UTF-8 bash -c '
    clear(){ :; }; bat(){ printf 85%%; }; bl(){ printf 60; }; blm(){ printf 100; }
    vol(){ printf 40%%; }; temp(){ printf 45.0C; }
    source "'"$WORK/fn.sh"'" 2>/dev/null
    printf "4\n0\n" | m_timeout
' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$WORK/to.txt"
# Split on the top border: screen 1 is the first ╔ block, screen 2 the second.
awk '/╔/{n++} n==1' "$WORK/to.txt" > "$WORK/to1.txt"
awk '/╔/{n++} n==2' "$WORK/to.txt" > "$WORK/to2.txt"
[ -s "$WORK/to2.txt" ] && ok "selecting a value redraws the screen in place" \
    || bad "no second screen was drawn - the picker did not refresh"
grep -qF '5 min  (current)' "$WORK/to1.txt" \
    && ok "first screen marks the stored value (5 min)" \
    || bad "first screen does not mark 5 min as current"
grep -qF '30 min  (current)' "$WORK/to2.txt" \
    && ok "second screen already marks the newly selected 30 min" \
    || bad "marker did not move to 30 min: [$(grep -F 'min' "$WORK/to2.txt" | tr -s ' ' | tr '\n' ';')]"
grep -qF '5 min  (current)' "$WORK/to2.txt" \
    && bad "the stale marker is still on 5 min" \
    || ok "the stale marker is gone from 5 min"
eq "the selection was persisted to the config" "30" "$(cat "$CONF2")"
# Row numbers map through the choice list, they are not the minute values: row 4
# is 30 minutes, not 4.
grep -qF '1 min' "$WORK/to2.txt" && grep -qF '10 min' "$WORK/to2.txt" \
    && ok "all four choices are listed" || bad "a choice is missing from the picker"

echo
echo "=== the reads use IFS= so TAB survives ==="
# Without IFS=, bash strips TAB as IFS whitespace and it arrives empty - the same
# value as ENTER - so the gate would accept a bare ENTER. Measured, not assumed.
plain=$(printf '\t' | { read -r -n1 -s c; printf '%s' "${#c}"; })
withifs=$(printf '\t' | { IFS= read -r -n1 -s c; printf '%s' "${#c}"; })
[ "$plain" = 0 ] && [ "$withifs" = 1 ] \
   && ok "confirmed: plain read loses TAB (len 0), IFS= read keeps it (len 1)" \
   || bad "TAB-preservation assumption changed: plain=$plain IFS=$withifs"
ds_body=$(awk '/^do_standby\(\) \{/,/^\}/' "$MT" | sed 's/#.*//')
# Strip comments first: the prose in do_standby says "read" three times, and
# counting those would compare 8 against 5 and fail on a correct function.
eq "every read in do_standby uses IFS=" \
   "$(printf '%s\n' "$ds_body" | grep -cE '\bread\b')" \
   "$(printf '%s\n' "$ds_body" | grep -c 'IFS= read')"

echo
echo "=== standby notice layout ==="
LC_ALL=C.UTF-8 bash -c '
    clear(){ :; }; bat(){ printf 85%%; }; bl(){ printf 60; }; blm(){ printf 100; }
    vol(){ printf 40%%; }; temp(){ printf 45.0C; }
    source "'"$WORK/fn.sh"'" 2>/dev/null; standby_screen' 2>/dev/null \
  | sed 's/\x1b\[[0-9;]*m//g' > "$WORK/sb.txt"
sb_bad=0; sb_rows=0
while IFS= read -r l; do
    sb_rows=$((sb_rows+1)); [ "${#l}" -eq 53 ] || { bad "standby row is ${#l} wide: [$l]"; sb_bad=1; }
done < "$WORK/sb.txt"
[ "$sb_bad" = 0 ] && ok "all $sb_rows standby rows are exactly 53 columns"
[ "$sb_rows" -le 14 ] && ok "standby fits the 14-row budget ($sb_rows rows)" \
    || bad "standby needs $sb_rows rows, budget is 14"
grep -qF 'S T A N D   B Y' "$WORK/sb.txt" && ok "shows the STAND BY notice" \
    || bad "STAND BY notice missing"
grep -qF 'press TAB, then ENTER to resume' "$WORK/sb.txt" \
    && ok "tells the user how to resume" || bad "resume hint missing"

echo
echo "=== wiring into the menu ==="
grep -q 'Screen timeout' "$MT" && ok "SYSTEM menu offers Screen timeout" \
    || bad "SYSTEM menu has no Screen timeout entry"
grep -q "'!m_timeout'" "$MT" && ok "Screen timeout opens m_timeout without a pause" \
    || bad "Screen timeout is not wired to m_timeout"
grep -q '^m_timeout()' "$MT" && ok "m_timeout is defined" || bad "m_timeout is missing"
choices=$(grep -oE 'CZ_STANDBY_CHOICES:-[^}]*' "$SB" | head -1 | sed 's/.*:-//')
for m in 1 5 10 30; do
    case " $choices " in
        *" $m "*) ok "the $m-minute choice is offered" ;;
        *) bad "$m minutes is missing from CZ_STANDBY_CHOICES=[$choices]" ;;
    esac
done
grep -q 'for m in $CZ_STANDBY_CHOICES' "$MT" \
    && ok "m_timeout builds its rows from CZ_STANDBY_CHOICES, not a hardcoded list" \
    || bad "m_timeout does not iterate CZ_STANDBY_CHOICES"
eq "every idle read site uses cz_standby_seconds" "4" \
   "$(grep -c 'secs=$(cz_standby_seconds)' "$MT")"
eq "every idle read site uses read -t" "5" \
   "$(grep -c 'IFS= read -t "$secs" -r -n1 -s k' "$MT")"
# Count, do not grep -q: there are two idle reads (menu and the main loop) and a
# mutation that fixes the comparison in only one of them still satisfies a
# presence check. Verified - that is exactly how M5 slipped through first time.
# Count, do not grep -q, and re-measure after any change: the guard now appears
# in do_standby (2), m_timeout, menu and the main loop.
eq "every idle read distinguishes timeout from EOF via rc>128" "5" \
   "$(grep -c 'rc" -gt 128' "$MT")"
grep -q 'STANDBY_TO_MAIN' "$MT" && ok "a submenu standby unwinds to the main menu" \
    || bad "no unwind-to-main-menu flag"

echo
echo "=== install wiring ==="
grep -q 'install -D -m 0644 files/cz-standby.sh  *"${ROOTFS_DIR}/usr/local/lib/cz-standby.sh"' "$INSTALL" \
    && ok "01-run.sh installs cz-standby.sh to /usr/local/lib" \
    || bad "01-run.sh does not install cz-standby.sh"

echo
if [ "$fail" = 0 ]; then echo "CZ-STANDBY OK"; else echo "CZ-STANDBY PROBLEM"; exit 1; fi
