#!/bin/bash
# Unit test for cz-display-switch: tty1 pinned to the 320x170 panel, tty2-6
# parked on the vc4 HDMI fb when one exists (phantom or real), so an external
# monitor gets its own getty terminal and the panel never goes blank.
# Runs the real script against a fake sysfs tree (CZ_DS_ROOT) with a stub
# con2fbmap so the mapping decisions are observable.
# Run: bash tests/cz-display-switch.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SW="$HERE/../stage2/05-cardputerzero/files/cz-display-switch"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

STUB="$WORK/bin"
mkdir -p "$STUB"
cat > "$STUB/con2fbmap" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$1" "$2" >> "$MAPLOG"
EOF
chmod +x "$STUB/con2fbmap"
cat > "$STUB/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SYSLOG"
EOF
chmod +x "$STUB/systemctl"
export PATH="$STUB:$PATH"

mk_sysfs() {   # $1 = root; creates panel fb0
    local r="$1"
    mkdir -p "$r/sys/class/graphics/fb0" "$r/lock"
    echo "320,170"         > "$r/sys/class/graphics/fb0/virtual_size"
    echo "panel-mipi-dbid" > "$r/sys/class/graphics/fb0/name"
}

add_hdmi_fb() {  # $1 = root
    mkdir -p "$1/sys/class/graphics/fb1"
    echo "1920,1080" > "$1/sys/class/graphics/fb1/virtual_size"
    echo "vc4drmfb"  > "$1/sys/class/graphics/fb1/name"
}

run() {  # $1 = root
    : > "$1/maplog"
    MAPLOG="$1/maplog" SYSLOG="$1/syslog" CZ_DS_ROOT="$1" CZ_DS_LOCK="$1/lock/l" \
        CZ_DS_SETTLE=0 CZ_DS_STATE="$1/state" bash "$SW"
}

maps() { local n; n=$(grep -c "^$1$" "$2/maplog" 2>/dev/null || true); echo "${n:-0}"; }

restarts() { local n; n=$(grep -c 'restart getty@tty2.service' "$1/syslog" 2>/dev/null || true); echo "${n:-0}"; }

echo "=== panel only: every VT stays on the panel ==="
R="$WORK/panelonly"; mk_sysfs "$R"
run "$R"
[ "$(maps '1 0' "$R")" = 1 ] && ok "tty1 on the panel" || bad "tty1 not on panel: $(cat "$R/maplog" | tr '\n' ';')"
[ "$(maps '2 0' "$R")" = 1 ] && ok "tty2 on the panel" || bad "tty2 not on panel"
[ "$(maps '6 0' "$R")" = 1 ] && ok "tty6 on the panel" || bad "tty6 not on panel"
[ "$(restarts "$R")" = 0 ] \
    && ok "no getty restart without an HDMI fb" || bad "getty restarted without an HDMI fb"

echo "=== vc4 HDMI fb present (phantom or real): tty1 pinned, tty2-6 parked on it ==="
R="$WORK/hdmi"; mk_sysfs "$R"; add_hdmi_fb "$R"
run "$R"
[ "$(maps '1 0' "$R")" = 1 ] && ok "tty1 pinned to the panel despite the HDMI fb" || bad "tty1 left the panel: $(cat "$R/maplog" | tr '\n' ';')"
[ "$(maps '1 1' "$R")" = 0 ] && ok "tty1 never mapped to the HDMI fb" || bad "tty1 was mapped to HDMI"
[ "$(maps '2 1' "$R")" = 1 ] && ok "tty2 parked on the HDMI fb (monitor terminal)" || bad "tty2 not on HDMI fb"
[ "$(maps '6 1' "$R")" = 1 ] && ok "tty6 parked on the HDMI fb" || bad "tty6 not on HDMI fb"
[ "$(restarts "$R")" = 1 ] \
    && ok "getty@tty2 restarted so its prompt redraws on the monitor" \
    || bad "getty@tty2 not restarted on HDMI fb appearance"

echo "=== re-run after fbcon drift re-asserts the same mapping ==="
MAPLOG="$R/maplog" SYSLOG="$R/syslog" CZ_DS_ROOT="$R" CZ_DS_LOCK="$R/lock/l" \
    CZ_DS_SETTLE=0 CZ_DS_STATE="$R/state" bash "$SW"
[ "$(maps '1 0' "$R")" = 2 ] && ok "second run re-pins tty1 to the panel" || bad "re-run did not re-pin tty1"
[ "$(restarts "$R")" = 1 ] \
    && ok "no redundant getty restart when state is unchanged" \
    || bad "getty@tty2 restarted again on an unchanged state"

echo "=== no panel framebuffer: bail out without touching anything ==="
R="$WORK/nopanel"; mk_sysfs "$R"; add_hdmi_fb "$R"
rm -r "$R/sys/class/graphics/fb0"
run "$R"
[ ! -s "$R/maplog" ] && ok "no mapping attempted" || bad "mapped without a panel: $(cat "$R/maplog" | tr '\n' ';')"

echo
if [ "$fail" = 0 ]; then echo "CZ-DISPLAY-SWITCH OK"; else echo "CZ-DISPLAY-SWITCH PROBLEM"; exit 1; fi
