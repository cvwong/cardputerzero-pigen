#!/bin/bash
# Tests for the monitor console design: tty1 on the panel, tty2 on the HDMI fb,
# with the kernel keymap switching between them in both directions.
#
# This replaced a cage+foot compositor. The compositor made the two directions
# asymmetric: Alt+M worked because the kernel keymap handles it below userspace,
# but once cage held the input seat that same keymap was bypassed, so returning
# to the panel depended entirely on a foot keybinding - and when that binding
# did not fire there was no key left that could get back, only SSH. A plain
# console has no such asymmetry: the same kernel keymap works on both VTs.
#
# It also guards the pi-gen cache trap from 4cf5032: dropping an install line,
# or a package from 00-packages, does NOT remove it from a cached rootfs, so
# every retired path and package must be purged explicitly.
# Run: bash tests/cz-monitor-console.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FEAT="$HERE/../stage2/06-cpz-features"
RUN="$FEAT/01-run.sh"
PKGS="$FEAT/00-packages"
KEYMAP="$FEAT/files/cz-console-switch.map"
CZKEYMAP="$FEAT/files/cz-keymap"
AUTOSTART="$FEAT/files/cz-autostart.sh"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

echo "=== the monitor console has a login ==="
grep -q 'systemctl enable getty@tty2.service' "$RUN" \
    && ok "getty@tty2 is enabled" \
    || bad "getty@tty2 is not enabled - the monitor shows a dead console until logind autospawns one"

echo "=== the kernel keymap switches BOTH ways ==="
grep -qE '^alt keycode [0-9]+ = Console_1$' "$KEYMAP" && ok "Alt+? -> Console_1 (back to the panel)" \
    || bad "no Console_1 binding - there is no way back to the panel"
grep -qE '^alt keycode [0-9]+ = Console_2$' "$KEYMAP" && ok "Alt+? -> Console_2 (out to the monitor)" \
    || bad "no Console_2 binding"
[ "$(grep -cE '^alt keycode [0-9]+ = Console_[0-9]+$' "$KEYMAP")" = 2 ] \
    && ok "exactly the two VT-switch bindings" || bad "unexpected binding count in the keymap"

echo "=== that keymap is actually loaded, on the monitor VT too ==="
grep -q 'cz-console-switch.map' "$RUN" && ok "01-run.sh installs the switch map" \
    || bad "the switch map is never installed - loadkeys would find nothing"
grep -qE '^SWITCH=.*cz-console-switch\.map' "$CZKEYMAP" && ok "cz-keymap loads it" \
    || bad "cz-keymap does not load the switch map"
# Alt+P has to work while sitting on tty2, so the map must be loaded there.
case "$(grep -oE 'for t in [^;]*;' "$CZKEYMAP" | head -1)" in
    *"2"*) ok "loaded on tty2 as well as tty1" ;;
    *) bad "tty2 is not in cz-keymap's loop: $(grep -oE 'for t in [^;]*;' "$CZKEYMAP" | head -1)" ;;
esac
grep -qE 'loadkeys .*"\$SWITCH"' "$CZKEYMAP" && ok "loadkeys is called with the switch map" \
    || bad "cz-keymap never calls loadkeys on \$SWITCH"

echo "=== nothing still installs or enables the compositor stack ==="
for pat in 'install.*cz-cage' 'install.*cz-monitor-session' 'install.*foot\.ini' \
           'enable.*seatd' 'enable.*cz-cage'; do
    grep -qE "$pat" "$RUN" && bad "01-run.sh still has: $pat" || ok "no '$pat' in 01-run.sh"
done
for p in cage foot seatd; do
    grep -qE "^$p\$" "$PKGS" && bad "00-packages still lists $p" || ok "$p removed from 00-packages"
done
for f in cz-cage.service cz-cage-watcher.service cz-cage-watcher cz-monitor-session foot.ini; do
    [ -e "$FEAT/files/$f" ] && bad "retired file still present: files/$f" || ok "files/$f deleted"
done

echo "=== the cached rootfs is purged, not just left behind (4cf5032's trap) ==="
grep -q 'apt-get purge -y cage foot seatd' "$RUN" \
    && ok "packages purged in the chroot" \
    || bad "no apt-get purge - dropping them from 00-packages leaves them installed in a cached rootfs"
# Every path a retired build installed must appear in the rm -f block, or a
# cached rootfs ships it forever with no unit to run it.
for p in usr/local/bin/cz-monitor-session \
         usr/local/sbin/cz-cage-watcher \
         etc/systemd/system/cz-cage.service \
         etc/systemd/system/cz-cage-watcher.service \
         etc/systemd/system/multi-user.target.wants/cz-cage.service \
         etc/systemd/system/multi-user.target.wants/cz-cage-watcher.service \
         etc/foot/foot.ini; do
    grep -qF "\${ROOTFS_DIR}/$p" "$RUN" && ok "purges $p" || bad "$p is never purged from the cached rootfs"
done
grep -q 'systemctl disable cz-cage-watcher.service seatd.service' "$RUN" \
    && ok "disables the retired units before deleting them" \
    || bad "retired units are not disabled - dangling enable symlinks would remain"

echo "=== the panel-login flag that gated the old Waiting screen is gone ==="
grep -q 'cz-panel-login' "$AUTOSTART" && bad "cz-autostart.sh still writes the vestigial flag" \
    || ok "cz-autostart.sh no longer writes /run/cz-panel-login"
grep -rq 'cz-panel-login' "$FEAT" 2>/dev/null && bad "something still references cz-panel-login" \
    || ok "no remaining reference to cz-panel-login"

echo
if [ "$fail" = 0 ]; then echo "CZ-MONITOR-CONSOLE OK"; else echo "CZ-MONITOR-CONSOLE PROBLEM"; exit 1; fi
