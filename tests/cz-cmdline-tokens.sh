#!/bin/bash
# E2E test for stage2/05-cardputerzero/02-run.sh's cmdline.txt rewrite.
#
# The load-bearing assertion is that the ` resize` token is dropped. Leaving it
# in makes the initramfs run resize_early + set_partuuid before switch_root, and
# on 2026-11-26 that boot never reached systemd: the partition had been grown and
# both filesystems left dirty, but the MBR disk id was unchanged, cmdline had not
# been rewritten and no file on the rootfs was touched. Removing the token by
# hand made the same card boot immediately.
#
# The stage runs again on every build against pi-gen's cached rootfs, so the
# rewrite must also be idempotent - a second pass has to produce the same line
# rather than appending duplicate tokens.
# Run: bash tests/cz-cmdline-tokens.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$HERE/../stage2/05-cardputerzero/02-run.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

# Raw pi-gen cmdline for a trixie image, plus tokens the stage must strip.
INPUT='console=serial0,115200 console=tty1 root=PARTUUID=abcd1234-02 rootfstype=ext4 fsck.repair=yes rootwait resize quiet splash loglevel=1 fbcon=map:1 video=HDMI-A-1:d'
EXPECT='console=serial0,115200 console=tty1 root=PARTUUID=abcd1234-02 rootfstype=ext4 fsck.repair=yes rootwait fbcon=map:0 fbcon=font:VGA8x8 consoleblank=0 quiet loglevel=2 logo.nologo cfg80211.ieee80211_regdom=US video=HDMI-A-1:1920x1080MR@60D'

mkroot() {
    R="$WORK/$1"
    mkdir -p "$R/boot/firmware" "$R/etc/modules-load.d" "$R/etc/modprobe.d"
    printf '%s\n' "$INPUT" > "$R/boot/firmware/cmdline.txt"
    printf 'splash_screen=1\ngpu_mem=64\ndtoverlay=vc4-kms-v3d\n' > "$R/boot/firmware/config.txt"
}
run_stage() { ROOTFS_DIR="$R" bash "$STAGE" >"$WORK/stage.log" 2>&1; }
cmdline() { cat "$R/boot/firmware/cmdline.txt"; }
has_tok() { local t; for t in $(cmdline); do [ "$t" = "$1" ] && return 0; done; return 1; }
count_tok() { local t n=0; for t in $(cmdline); do [ "$t" = "$1" ] && n=$((n+1)); done; echo "$n"; }

echo "=== the token that hung the boot ==="
mkroot a; run_stage
[ -s "$WORK/stage.log" ] && sed 's/^/  stage said: /' "$WORK/stage.log"
if has_tok resize; then bad "'resize' survived - the initramfs resize path still runs"; else ok "'resize' dropped from cmdline.txt"; fi
# A substring test would pass on 'resize2fs'; check the exact word is absent too.
case " $(cmdline) " in *" resize "*) bad "word-boundary check also found resize" ;;
    *) ok "no resize as a standalone word" ;; esac

echo "=== everything needed to boot is still there ==="
for t in "root=PARTUUID=abcd1234-02" rootfstype=ext4 rootwait fsck.repair=yes console=tty1; do
    has_tok "$t" && ok "kept $t" || bad "lost $t"
done

echo "=== the stage's own canonical tokens ==="
for t in quiet loglevel=2 logo.nologo consoleblank=0 fbcon=map:0 fbcon=font:VGA8x8 \
         cfg80211.ieee80211_regdom=US video=HDMI-A-1:1920x1080MR@60D; do
    has_tok "$t" && ok "has $t" || bad "missing $t"
done
for t in splash loglevel=1 fbcon=map:1 video=HDMI-A-1:d; do
    has_tok "$t" && bad "stale $t not dropped" || ok "dropped $t"
done

echo "=== the HDMI mode must carry CVT reduced-blanking flags ==="
# Both flags are load-bearing, and dropping either silently reintroduces a mode
# vc4 refuses. Observed on hardware 2026-11-27 with plain 1920x1080@60:
#   [drm] User-defined mode not supported: "1920x1080": 60 172780 ... htotal 2576
# 172780 kHz exceeds what vc4 accepts (it drives the EDID/CEA mode at 148500 kHz).
# Reduced blanking gives htotal 2080 and 138653 kHz. With no accepted user mode
# and no EDID the connector is left at drm_add_modes_noedid's 1024x768 ceiling.
VID=$(for t in $(cmdline); do case "$t" in video=HDMI-A-1:*) echo "$t";; esac; done | head -1)
MODE=${VID#video=HDMI-A-1:}; MODE=${MODE%%@*}
case "$MODE" in *M*) ok "M flag present (CVT timings, not GTF)" ;;
    *) bad "no M flag in '$MODE'" ;; esac
case "$MODE" in *R*) ok "R flag present (reduced blanking keeps the clock acceptable)" ;;
    *) bad "no R flag in '$MODE' - plain CVT is 172780 kHz, which vc4 rejects" ;; esac
case "$VID" in *"1920x1080"*"@60"*) ok "still 1920x1080 at 60 Hz" ;;
    *) bad "resolution/refresh changed: $VID" ;; esac
case "$VID" in *D) ok "force-on flag D retained" ;;
    *) bad "force-on flag D lost: $VID" ;; esac

echo "=== exact resulting line ==="
if [ "$(cmdline)" = "$EXPECT" ]; then ok "cmdline matches the expected canonical line"; else
    bad "unexpected cmdline"; echo "    got:      $(cmdline)"; echo "    expected: $EXPECT"; fi
[ "$(wc -l < "$R/boot/firmware/cmdline.txt")" = 1 ] && ok "still a single line" \
    || bad "cmdline.txt is not one line - the kernel only reads the first"

echo "=== idempotent across builds (the rootfs is cached, this runs every time) ==="
run_stage; run_stage
if [ "$(cmdline)" = "$EXPECT" ]; then ok "two more passes changed nothing"
else bad "re-running duplicated tokens"; echo "    got: $(cmdline)"; fi
[ "$(count_tok console=tty1)" = 1 ] && ok "console=tty1 appears once" \
    || bad "console=tty1 duplicated: $(count_tok console=tty1)"

echo "=== KEEP_SERIAL_CONSOLE=0 drops the serial console ==="
mkroot b
ROOTFS_DIR="$R" KEEP_SERIAL_CONSOLE=0 bash "$STAGE" >/dev/null 2>&1
has_tok "console=serial0,115200" && bad "serial console kept despite KEEP_SERIAL_CONSOLE=0" \
    || ok "serial console dropped"
if has_tok resize; then bad "resize survived with KEEP_SERIAL_CONSOLE=0"; else ok "resize still dropped"; fi

echo "=== KEEP_SERIAL_CONSOLE=1 (default) keeps it ==="
mkroot c; run_stage
has_tok "console=serial0,115200" && ok "serial console kept by default" \
    || bad "serial console dropped by default"

echo "=== config.txt side effects are unaffected ==="
mkroot d; run_stage
[ "$(head -1 "$R/boot/firmware/config.txt")" = "gpu_mem=32" ] && ok "gpu_mem=32 forced to line 1" \
    || bad "gpu_mem not first: $(head -1 "$R/boot/firmware/config.txt")"
grep -q '^splash_screen=' "$R/boot/firmware/config.txt" && bad "splash_screen not removed" \
    || ok "splash_screen removed"
[ "$(grep -c '^gpu_mem=' "$R/boot/firmware/config.txt")" = 1 ] && ok "exactly one gpu_mem line" \
    || bad "gpu_mem duplicated"
grep -q 'dtoverlay=vc4-kms-v3d' "$R/boot/firmware/config.txt" && ok "rest of config.txt preserved" \
    || bad "config.txt lost content"

echo
if [ "$fail" = 0 ]; then echo "CZ-CMDLINE-TOKENS OK"; else echo "CZ-CMDLINE-TOKENS PROBLEM"; exit 1; fi
