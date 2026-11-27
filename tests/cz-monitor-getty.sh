#!/bin/bash
# Tests for the monitor console's login banner (getty@tty2).
#
# Alt+M/Alt+p switching is verified working on hardware; what remained was that
# the monitor printed the *panel's* banner. getty@tty2 had no --issue-file, so
# agetty fell back to /etc/issue - the 53-column box cz-issue generates for the
# handheld - and --noclear appended it on every getty start, stacking boxes down
# the screen. The user reported exactly that: several CARDPUTER ZERO boxes.
#
# The panel's own banner must not change: it is generated at display time by
# cz-issue from getty@tty1's ExecStartPre, and restarting that getty to refresh
# it discards a half-typed username.
# Run: bash tests/cz-monitor-getty.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FEAT="$HERE/../stage2/06-cpz-features"
RUN="$FEAT/01-run.sh"
MON="$FEAT/files/10-cz-monitor.conf"
PANEL="$FEAT/files/10-cz-issue.conf"
BANNER="$FEAT/files/issue.cz-monitor"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

echo "=== the drop-in overrides ExecStart correctly ==="
[ -f "$MON" ] && ok "10-cz-monitor.conf exists" || bad "the drop-in is missing"
# getty@.service is Type=idle, which allows exactly one ExecStart. Appending
# without resetting first makes the unit fail to load, taking the monitor login
# with it.
grep -qx 'ExecStart=' "$MON" && ok "resets ExecStart before setting it" \
    || bad "no bare 'ExecStart=' reset - Type=idle permits only one, so the unit would not load"
reset_line=$(grep -nx 'ExecStart=' "$MON" | head -1 | cut -d: -f1)
set_line=$(grep -n '^ExecStart=-/sbin/agetty' "$MON" | head -1 | cut -d: -f1)
if [ -n "$reset_line" ] && [ -n "$set_line" ] && [ "$reset_line" -lt "$set_line" ]; then
    ok "the reset comes first (line $reset_line before $set_line)"
else
    bad "reset must precede the new ExecStart: reset=$reset_line set=$set_line"
fi

echo "=== the two defects are actually gone ==="
# Strip comments first: both drop-ins explain in prose why --noclear is wrong, so
# grepping the whole file matches the explanation rather than the code. This is
# the third time that trap has produced a false result in this suite.
MONCODE=$(grep -v '^[[:space:]]*#' "$MON")
PANELCODE=$(grep -v '^[[:space:]]*#' "$PANEL")
case "$MONCODE" in *--noclear*) bad "--noclear is still there - boxes will keep stacking" ;;
    *) ok "no --noclear, so the screen is cleared" ;; esac
case "$MONCODE" in *"--issue-file /etc/issue.cz-monitor"*) ok "points at the monitor banner" ;;
    *) bad "not using the monitor issue file" ;; esac
# The panel banner is /etc/issue exactly; matching it would defeat the whole fix.
case "$MONCODE" in *"--issue-file /etc/issue "*|*"--issue-file /etc/issue") bad "still points at /etc/issue (the panel box)" ;;
    *) ok "does not fall back to the panel's /etc/issue" ;; esac
grep -qF -- "-o '-- \\\\u'" "$MON" && ok "keeps agetty's -o '-- \\u' username handling" \
    || bad "the -o escaping differs from the panel drop-in"

echo "=== the banner suits an external display ==="
[ -f "$BANNER" ] && ok "issue.cz-monitor exists" || bad "the banner file is missing"
if grep -qE '[╔╗╚╝║═]' "$BANNER"; then
    bad "the monitor banner contains box-drawing characters - that is the panel's 53-column box"
else
    ok "no box-drawing characters (the 53-column convention is the handheld's)"
fi
grep -q 'Alt+p' "$BANNER" && ok "tells the user how to get back to the panel" \
    || bad "no Alt+p hint - the return key is the whole point of the console design"

echo "=== both files are installed where the unit expects them ==="
grep -qF '"${ROOTFS_DIR}/etc/systemd/system/getty@tty2.service.d/10-cz-monitor.conf"' "$RUN" \
    && ok "drop-in installed to getty@tty2.service.d" || bad "drop-in is never installed"
grep -qF '"${ROOTFS_DIR}/etc/issue.cz-monitor"' "$RUN" \
    && ok "banner installed to the path the drop-in references" \
    || bad "banner is not installed to /etc/issue.cz-monitor"

echo "=== the panel's own banner is untouched ==="
grep -q '^ExecStartPre=-/usr/local/sbin/cz-issue$' "$PANEL" \
    && ok "tty1 still regenerates its banner at display time" || bad "tty1's ExecStartPre was disturbed"
grep -q -- '--issue-file /etc/issue ' "$PANEL" && ok "tty1 still uses /etc/issue" \
    || bad "tty1's issue file changed"
case "$PANELCODE" in *--noclear*) bad "noclear crept into the panel drop-in" ;;
    *) ok "panel drop-in has no --noclear" ;; esac
# The monitor fix must not add a getty@tty1 restart anywhere: that discards a
# half-typed username.
grep -rn 'restart getty@tty1\|restart.*getty@tty1' "$FEAT" 2>/dev/null \
    && bad "something restarts getty@tty1" || ok "nothing restarts getty@tty1"

echo
if [ "$fail" = 0 ]; then echo "CZ-MONITOR-GETTY OK"; else echo "CZ-MONITOR-GETTY PROBLEM"; exit 1; fi
