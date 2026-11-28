#!/bin/bash
# cz-standby.sh — idle screen-blank for the CardputerZero console menu.
# Sourced by cz-menu-theme. Not meant to be executed on its own.
#
# Installed to /usr/local/lib/cz-standby.sh. Callers locate it via:
#   CZ_STANDBY="${CZ_STANDBY:-/usr/local/lib/cz-standby.sh}"
# which the tests override to point at the copy in the source tree.
#
# Everything here runs unprivileged: the backlight sysfs node is writable by the
# console user on this image, and /dev/fbN is crw-rw---- root:video with the
# console user in `video`, so the FBIOBLANK ioctl needs no root either.
#
# The panel framebuffer INDEX IS NOT STABLE across boots - fb0 has been both
# panel-mipi-dbid and vc4drmfb on the same hardware, and was observed to swap
# between two boots on 2026-11-28. The panel is therefore resolved by its
# 320x170 virtual_size, the same test /usr/local/sbin/lcd-console uses. Never
# hardcode an fb index here.

CZ_STANDBY_CONF="${CZ_STANDBY_CONF:-${HOME:-/tmp}/.config/cz-standby.conf}"
CZ_STANDBY_CHOICES="${CZ_STANDBY_CHOICES:-1 5 10 30}"   # minutes
CZ_STANDBY_DEFAULT="${CZ_STANDBY_DEFAULT:-5}"           # minutes
CZ_SYS_GRAPHICS="${CZ_SYS_GRAPHICS:-/sys/class/graphics}"

# Index of the 320x170 panel framebuffer, or non-zero if there is none.
cz_panel_fb() {
    local d
    for d in "$CZ_SYS_GRAPHICS"/fb[0-9]*; do
        [ -r "$d/virtual_size" ] || continue
        case "$(cat "$d/virtual_size" 2>/dev/null)" in
            320,170 | 170,320) printf '%s' "${d##*/fb}"; return 0 ;;
        esac
    done
    return 1
}

# FBIOBLANK on the panel: 0 = VESA_NO_BLANKING (wake), 4 = FB_BLANK_POWERDOWN.
# bash cannot issue an ioctl, so python3 does; cz-splash uses the same call.
cz_fb_blank() { # cz_fb_blank <fb-index> <mode>
    local idx="$1" mode="$2"
    [ -n "$idx" ] && [ -n "$mode" ] || return 1
    CZ_FB_DEV="${CZ_FB_DIR:-/dev}/fb$idx" CZ_FB_ARG="$mode" python3 -c '
import fcntl, os
fd = os.open(os.environ["CZ_FB_DEV"], os.O_RDWR)
try:
    fcntl.ioctl(fd, 0x4611, int(os.environ["CZ_FB_ARG"]))
finally:
    os.close(fd)
' 2>/dev/null
}

cz_standby_bl_dir() { printf '%s' "${BL:-${CZ_BACKLIGHT:-/sys/class/backlight/backlight}}"; }

# Current timeout in minutes. Anything absent or outside the offered choices
# falls back to the default, so a hand-edited or corrupt config cannot leave the
# menu with an unusable `read -t` argument.
cz_standby_minutes() {
    local m=""
    [ -r "$CZ_STANDBY_CONF" ] && m="$(head -1 "$CZ_STANDBY_CONF" 2>/dev/null)"
    m="${m%%[!0-9]*}"                       # strip anything non-numeric
    case " $CZ_STANDBY_CHOICES " in
        *" $m "*) ;;
        *) m="$CZ_STANDBY_DEFAULT" ;;
    esac
    printf '%s' "$m"
}

cz_standby_seconds() { printf '%s' $(( $(cz_standby_minutes) * 60 )); }

# Only an offered choice can be written; anything else is rejected rather than
# silently stored.
cz_standby_set_minutes() {
    case " $CZ_STANDBY_CHOICES " in
        *" $1 "*) ;;
        *) return 1 ;;
    esac
    mkdir -p "$(dirname "$CZ_STANDBY_CONF")" 2>/dev/null || return 1
    printf '%s\n' "$1" > "$CZ_STANDBY_CONF"
}

# Blank the panel: backlight to 0 and FBIOBLANK powerdown. The previous
# brightness is kept in a variable, not a file - blank and wake always happen
# inside the same menu process, and lcd-console restores full brightness at boot
# anyway, so a crash mid-standby cannot leave the panel dark permanently.
cz_standby_blank() {
    local bl fb
    bl="$(cz_standby_bl_dir)"
    CZ_STANDBY_SAVED_BL="$(cat "$bl/brightness" 2>/dev/null)"
    [ -w "$bl/brightness" ] && echo 0 > "$bl/brightness" 2>/dev/null
    fb="$(cz_panel_fb)" && cz_fb_blank "$fb" 4
    return 0
}

# Wake in the reverse order: FBIOBLANK first, because on panel-mipi-dbid
# restoring brightness alone does not bring a powered-down panel back.
cz_standby_wake() {
    local bl fb
    fb="$(cz_panel_fb)" && cz_fb_blank "$fb" 0
    bl="$(cz_standby_bl_dir)"
    if [ -n "${CZ_STANDBY_SAVED_BL:-}" ] && [ -w "$bl/brightness" ]; then
        echo "$CZ_STANDBY_SAVED_BL" > "$bl/brightness" 2>/dev/null
    fi
    return 0
}
