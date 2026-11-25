#!/bin/bash
# Unit test for cz-display-switch: exclusive console output selection.
# Runs the real script against a fake sysfs tree (CZ_DS_ROOT) with a stub
# con2fbmap, so the mapping decisions and backlight writes are observable.
# The case that matters most is the phantom vc4 fb (connected status but no
# EDID) that caused the blank-LCD incident: it must NOT take the console.
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
export PATH="$STUB:$PATH"

mk_sysfs() {   # $1 = root; creates panel fb0, backlight, drm connector
    local r="$1"
    mkdir -p "$r/sys/class/graphics/fb0" "$r/sys/class/backlight/backlight" \
             "$r/sys/class/drm/card0-HDMI-A-1" "$r/lock"
    echo "320,170"          > "$r/sys/class/graphics/fb0/virtual_size"
    echo "panel-mipi-dbid"  > "$r/sys/class/graphics/fb0/name"
    echo "100"              > "$r/sys/class/backlight/backlight/max_brightness"
    echo "100"              > "$r/sys/class/backlight/backlight/brightness"
    echo "disconnected"     > "$r/sys/class/drm/card0-HDMI-A-1/status"
    : > "$r/sys/class/drm/card0-HDMI-A-1/edid"
}

add_hdmi_fb() {  # $1 = root
    mkdir -p "$1/sys/class/graphics/fb1"
    echo "1920,1080" > "$1/sys/class/graphics/fb1/virtual_size"
    echo "vc4drmfb"  > "$1/sys/class/graphics/fb1/name"
}

run() {  # $1 = root
    : > "$1/maplog"
    MAPLOG="$1/maplog" CZ_DS_ROOT="$1" CZ_DS_LOCK="$1/lock/l" bash "$SW"
}

maps() { local n; n=$(grep -c "^$1$" "$2/maplog" 2>/dev/null || true); echo "${n:-0}"; }
bright() { cat "$1/sys/class/backlight/backlight/brightness"; }

echo "=== phantom vc4 fb (connected, no EDID) must not take the console ==="
R="$WORK/phantom"; mk_sysfs "$R"; add_hdmi_fb "$R"
echo connected > "$R/sys/class/drm/card0-HDMI-A-1/status"
run "$R"
[ "$(maps '1 0' "$R")" = 1 ] && ok "tty1 stays on the panel fb0" || bad "tty1 left the panel: $(cat "$R/maplog" | tr '\n' ';')"
[ "$(maps '2 1' "$R")" = 1 ] && ok "tty2-6 parked on the vc4 fb1" || bad "tty2-6 not on fb1"
[ "$(bright "$R")" = 100 ] && ok "panel backlight stays at max" || bad "backlight was $(bright "$R")"

echo "=== real monitor (connected + EDID) takes the console ==="
R="$WORK/real"; mk_sysfs "$R"; add_hdmi_fb "$R"
echo connected > "$R/sys/class/drm/card0-HDMI-A-1/status"
head -c 128 /dev/urandom > "$R/sys/class/drm/card0-HDMI-A-1/edid"
run "$R"
[ "$(maps '1 1' "$R")" = 1 ] && ok "tty1 moves to the HDMI fb1" || bad "tty1 not on fb1: $(cat "$R/maplog" | tr '\n' ';')"
[ "$(maps '1 0' "$R")" = 0 ] && ok "tty1 no longer on the panel" || bad "tty1 still mapped to panel too"
[ "$(bright "$R")" = 0 ] && ok "panel backlight off while on HDMI" || bad "backlight was $(bright "$R")"

echo "=== no HDMI framebuffer at all ==="
R="$WORK/panelonly"; mk_sysfs "$R"
run "$R"
[ "$(maps '1 0' "$R")" = 1 ] && ok "tty1 on the panel" || bad "tty1 not on panel"
[ "$(maps '2 0' "$R")" = 1 ] && ok "tty2-6 fall back to the panel" || bad "tty2-6 not on panel"
[ "$(bright "$R")" = 100 ] && ok "backlight at max" || bad "backlight was $(bright "$R")"

echo "=== monitor unplugged (fb still present, connector disconnected) ==="
R="$WORK/unplug"; mk_sysfs "$R"; add_hdmi_fb "$R"
echo disconnected > "$R/sys/class/drm/card0-HDMI-A-1/status"
head -c 128 /dev/urandom > "$R/sys/class/drm/card0-HDMI-A-1/edid"
run "$R"
[ "$(maps '1 0' "$R")" = 1 ] && ok "tty1 returns to the panel" || bad "tty1 not back on panel: $(cat "$R/maplog" | tr '\n' ';')"
[ "$(bright "$R")" = 100 ] && ok "backlight restored" || bad "backlight was $(bright "$R")"

echo "=== no panel framebuffer and no real monitor: bail out without touching anything ==="
R="$WORK/nopanel"; mk_sysfs "$R"; add_hdmi_fb "$R"
rm -r "$R/sys/class/graphics/fb0"
run "$R"
[ ! -s "$R/maplog" ] && ok "no mapping attempted" || bad "mapped without a panel: $(cat "$R/maplog" | tr '\n' ';')"

echo "=== no panel framebuffer but a real monitor: HDMI is the only output ==="
R="$WORK/nopanelmon"; mk_sysfs "$R"; add_hdmi_fb "$R"
rm -r "$R/sys/class/graphics/fb0"
echo connected > "$R/sys/class/drm/card0-HDMI-A-1/status"
head -c 128 /dev/urandom > "$R/sys/class/drm/card0-HDMI-A-1/edid"
run "$R"
[ "$(maps '1 1' "$R")" = 1 ] && ok "tty1 goes to the HDMI fb" || bad "tty1 not on fb1: $(cat "$R/maplog" | tr '\n' ';')"

echo
if [ "$fail" = 0 ]; then echo "CZ-DISPLAY-SWITCH OK"; else echo "CZ-DISPLAY-SWITCH PROBLEM"; exit 1; fi
