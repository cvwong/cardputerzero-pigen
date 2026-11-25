#!/bin/bash
# Unit test for cz-monitor-view: paints a centred "Waiting" on tty2 and
# freezes it onto the monitor fb with a chvt 2/1 repaint flicker. Runs with
# stubbed chvt/setfont/stty and a regular file standing in for /dev/tty2.
# Run: bash tests/cz-monitor-view.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
VIEW="$HERE/../stage2/06-cpz-features/files/cz-monitor-view"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

STUB="$WORK/bin"
mkdir -p "$STUB" "$WORK/sys/class/graphics/fb0"
echo vc4drmfb > "$WORK/sys/class/graphics/fb0/name"
cat > "$STUB/chvt" <<'EOF'
#!/bin/bash
printf 'chvt %s\n' "$1" >> "$CHVTLOG"
EOF
cat > "$STUB/setfont" <<'EOF'
#!/bin/bash
printf 'setfont %s\n' "$*" >> "$CHVTLOG"
EOF
cat > "$STUB/stty" <<'EOF'
#!/bin/bash
printf '67 60\n'
EOF
chmod +x "$STUB/chvt" "$STUB/setfont" "$STUB/stty"
export PATH="$STUB:$PATH"
: > "$WORK/tty2"
: > "$WORK/font.psf"

CHVTLOG="$WORK/log" CZ_MON_TTY2="$WORK/tty2" CZ_MON_ROOT="$WORK" \
    CZ_MON_FONT="$WORK/font.psf" CZ_MON_CHVT=chvt \
    CZ_MON_SETFONT=setfont CZ_MON_STTY=stty bash "$VIEW"
rc=$?

[ "$rc" = 0 ] && ok "exits 0 with an HDMI fb present" || bad "rc=$rc"
grep -q "Waiting" "$WORK/tty2" && ok "Waiting painted on tty2" || bad "no Waiting text: $(cat "$WORK/tty2")"
grep -q "setfont" "$WORK/log" && ok "big font applied to tty2" || bad "setfont not called"
grep -qx "chvt 2" "$WORK/log" && grep -qx "chvt 1" "$WORK/log" \
    && ok "repaint flicker chvt 2 then 1" || bad "flicker missing: $(cat "$WORK/log" | tr '\n' ';')"

echo "=== no HDMI fb: nothing painted ==="
rm -r "$WORK/sys/class/graphics/fb0"
: > "$WORK/tty2"; : > "$WORK/log"
CHVTLOG="$WORK/log" CZ_MON_TTY2="$WORK/tty2" CZ_MON_ROOT="$WORK" \
    CZ_MON_FONT="$WORK/font.psf" CZ_MON_CHVT=chvt \
    CZ_MON_SETFONT=setfont CZ_MON_STTY=stty bash "$VIEW"
[ ! -s "$WORK/tty2" ] && ok "tty2 untouched without an HDMI fb" || bad "painted without HDMI fb"

echo
if [ "$fail" = 0 ]; then echo "CZ-MONITOR-VIEW OK"; else echo "CZ-MONITOR-VIEW PROBLEM"; exit 1; fi
