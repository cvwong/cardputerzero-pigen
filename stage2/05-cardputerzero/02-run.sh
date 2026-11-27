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
            # The board HDMI HPD/EDID lines never assert, so the output must
            # be forced on with a fixed digital mode or the monitor stays dark.
            if (t ~ /^video=HDMI-A-1:/) continue
            # Probe-defer noise (e.g. bcm2835 spi -517) is KERN_ERR; keep it in
            # the journal but off every console, including the monitor fb.
            if (t ~ /^loglevel=/) continue
            # ` resize` makes the initramfs run resize_early (grows the
            # partition) and then set_partuuid, which randomises the MBR disk id
            # with `dd if=/dev/hwrng of=<disk> bs=4 seek=110`. On this board that
            # boot never reached switch_root: the partition had been grown and
            # root plus bootfs were left mounted rw, but the disk id was still
            # the image one, cmdline had not been rewritten, and systemd never
            # wrote a file. Dropping the token makes both scripts exit at once;
            # cardputerzero-resize.service grows the root filesystem from
            # userspace instead (installed by 01-run.sh). Side effect: the disk
            # id is no longer randomised, so every card from this image keeps the
            # same PARTUUIDs - harmless for one card per machine, and it keeps
            # cmdline.txt and /etc/fstab permanently consistent.
            if (t == "resize") continue
            if (keep != "1" && t == "console=serial0,115200") continue
            out = out (out == "" ? "" : " ") t
        }
        print out
    }' "$cmd" > "${cmd}.tmp"
    mv "${cmd}.tmp" "$cmd"

    # MR = CVT timings with reduced blanking, and both flags are load-bearing.
    # Plain 1920x1080@60 makes the kernel generate CVT timings with htotal 2576
    # and a 172780 kHz pixel clock, which vc4 refuses outright: "User-defined
    # mode not supported" (observed on hardware 2026-11-27). Reduced blanking
    # gives htotal 2080 and 138653 kHz, under the 148500 kHz CEA clock vc4 does
    # accept from EDID. With no accepted user mode and no EDID, the connector is
    # left with drm_add_modes_noedid's 1024x768 ceiling, so a monitor attached
    # after boot never gets 1080p.
    for tok in "console=tty1" "fbcon=map:0" "fbcon=font:${CONSOLE_FONT}" \
               "consoleblank=0" "quiet" "loglevel=2" "logo.nologo" \
               "cfg80211.ieee80211_regdom=${REGDOMAIN}" "video=HDMI-A-1:1920x1080MR@60D"; do
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
