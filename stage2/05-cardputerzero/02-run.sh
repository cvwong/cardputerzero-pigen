#!/bin/bash -e
# CardputerZero v5 - plain text console profile.

CONSOLE_FONT="${CONSOLE_FONT:-VGA8x8}"
KEEP_SERIAL_CONSOLE="${KEEP_SERIAL_CONSOLE:-1}"
REGDOMAIN="${REGDOMAIN:-US}"

for cmd in "${ROOTFS_DIR}/boot/firmware/cmdline.txt" "${ROOTFS_DIR}/boot/cmdline.txt"; do
    [ -f "$cmd" ] || continue

    awk -v keep="$KEEP_SERIAL_CONSOLE" '{
        out = ""
        for (i = 1; i <= NF; i++) {
            t = $i
            if (t == "splash" || t == "quiet" || t == "plymouth.ignore-serial-consoles") continue
            if (t ~ /^fbcon=/ || t ~ /^consoleblank=/ || t ~ /^logo\.nologo$/) continue
            if (t ~ /^cfg80211\.ieee80211_regdom=/) continue
            # ed5fcb5 shipped this token; cached rootfs cmdline.txt still carries
            # it and cz-display-switch supersedes it, so drop it on every build.
            if (t == "video=HDMI-A-1:d") continue
            # The board's HDMI HPD/EDID lines never assert, so the output must
            # be forced on with a fixed digital mode or the monitor stays dark.
            if (t ~ /^video=HDMI-A-1:/) continue
            if (keep != "1" && t == "console=serial0,115200") continue
            out = out (out == "" ? "" : " ") t
        }
        print out
    }' "$cmd" > "${cmd}.tmp"
    mv "${cmd}.tmp" "$cmd"

    for tok in "console=tty1" "fbcon=map:0" "fbcon=font:${CONSOLE_FONT}" \
               "consoleblank=0" "quiet" "loglevel=3" "logo.nologo" \
               "cfg80211.ieee80211_regdom=${REGDOMAIN}" "video=HDMI-A-1:1920x1080@60D"; do
        grep -qF -- "$tok" "$cmd" || sed -i "s|\$| ${tok}|" "$cmd"
    done
done

# No custom splash on a console image; give the VPU the minimum.
CFG="${ROOTFS_DIR}/boot/firmware/config.txt"
sed -i -e '/^splash_screen=/d' -e '/^gpu_mem=/d' "$CFG"
sed -i '1i gpu_mem=32' "$CFG"

# --- preserved non-GUI tail of upstream 02-run.sh ---
cat > "${ROOTFS_DIR}/etc/modules-load.d/cardputerzero.conf" << 'INNER'
i2c-dev
INNER

install -d "${ROOTFS_DIR}/etc/systemd/system"
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/system/systemd-backlight@backlight:backlight.service"

cat > "${ROOTFS_DIR}/etc/modprobe.d/blacklist-8192cu.conf" << 'INNER'
blacklist 8192cu
INNER

cat > "${ROOTFS_DIR}/etc/modprobe.d/rfkill_default.conf" << 'INNER'
options rfkill default_state=0
INNER

mkdir -p "${ROOTFS_DIR}/var/log/journal" "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
cat > "${ROOTFS_DIR}/etc/systemd/journald.conf.d/persist.conf" << 'INNER'
[Journal]
Storage=persistent
SystemMaxUse=50M
INNER
