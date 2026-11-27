#!/bin/bash
# cz-signal.sh — WiFi signal strength for the CardputerZero console.
# Sourced by cz-theme.sh (the bars in every menu header) and by cz-wifi (the
# Bars line of `cz-wifi signal`) so both report the same value on the same
# scale. Not meant to be executed on its own.
#
# Installed to /usr/local/lib/cz-signal.sh. Callers locate it via:
#   CZ_SIGNAL="${CZ_SIGNAL:-/usr/local/lib/cz-signal.sh}"
# which the tests override to point at the copy in the source tree.
#
# The source is /proc/net/wireless, not nmcli or iw:
#   - it is a kernel file, ~5ms; nmcli costs ~88ms per call and hdr() redraws
#     on every keypress, so a D-Bus round trip per redraw is not acceptable;
#   - it needs no interface name. Do not hardcode wlan0: brcmfmac exposes both
#     wlan0 and wlan1 and the CardputerZero associates on wlan1, while a USB
#     dongle appears as wlan2;
#   - an interface is listed only while it is associated, so presence in the
#     file already means "has a link" and no separate check is needed.
# iw would also work but lives in /usr/sbin, which a non-login PATH (e.g. a
# non-interactive ssh session) does not contain.

CZ_WIRELESS=${CZ_WIRELESS:-/proc/net/wireless}

# Emit "<kind> <value>" for the first associated interface: "d <dBm>" when the
# driver reports a negative level (the normal case), or "q <percent>" for
# drivers that do not set IW_QUAL_DBM and report 0-100 instead. Empty when
# nothing is associated. Fields are: $3 = link quality, $4 = level, both with
# a trailing dot.
sig_raw() {
    awk 'NR>2 { lvl=$4; q=$3; sub(/\.$/,"",lvl); sub(/\.$/,"",q)
                if (lvl+0 < 0) { print "d " lvl+0; exit }
                if (q+0  > 0) { print "q " q+0;  exit } }' "$CZ_WIRELESS" 2>/dev/null
}

# Signal strength as a fixed-width 4-character field, '|' filled and '.' empty.
# Emits nothing at all when there is no link, so a header can leave the field
# blank: "associated but unusable" (....) stays distinguishable from "no wifi"
# (no bars), and the title never shifts sideways when the radio comes or goes.
sig_bars() {
    local raw kind v n i out=''
    raw=$(sig_raw); [ -n "$raw" ] || return 0
    kind=${raw% *}; v=${raw#* }
    if [ "$kind" = d ]; then
        if   [ "$v" -ge -50 ]; then n=4
        elif [ "$v" -ge -60 ]; then n=3
        elif [ "$v" -ge -70 ]; then n=2
        elif [ "$v" -ge -80 ]; then n=1
        else n=0; fi
    else
        if   [ "$v" -ge 75 ]; then n=4
        elif [ "$v" -ge 50 ]; then n=3
        elif [ "$v" -ge 25 ]; then n=2
        else n=1; fi
    fi
    for i in 1 2 3 4; do if [ "$i" -le "$n" ]; then out+='|'; else out+='.'; fi; done
    printf '%s' "$out"
}
