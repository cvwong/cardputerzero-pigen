#!/bin/bash
# Verify CardputerZero image contains all required customizations.
# Usage: ./tools/verify-image.sh <image.img>
# Exit 0 = all checks pass, Exit 1 = failure (breaks CI)

set -euo pipefail

IMG="${1:?Usage: $0 <image.img>}"
ERRORS=0
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

fail() { echo "  ✗ $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "  ✓ $1"; }

echo "=========================================="
echo " CardputerZero Image Verification"
echo "=========================================="
echo " Image: $IMG"
echo ""

# --- Extract partitions ---
# Get partition offsets (sectors, 512 bytes each)
BOOT_START=$(fdisk -l "$IMG" 2>/dev/null | grep "W95 FAT32\|FAT32" | awk '{print $2}')
BOOT_END=$(fdisk -l "$IMG" 2>/dev/null | grep "W95 FAT32\|FAT32" | awk '{print $3}')
ROOT_START=$(fdisk -l "$IMG" 2>/dev/null | grep "Linux" | awk '{print $2}')
ROOT_END=$(fdisk -l "$IMG" 2>/dev/null | grep "Linux" | awk '{print $3}')

BOOT_SECTORS=$((BOOT_END - BOOT_START + 1))
ROOT_SECTORS=$((ROOT_END - ROOT_START + 1))

echo "[1/6] Extracting partitions..."
dd if="$IMG" of="$TMPDIR/boot.fat" bs=512 skip="$BOOT_START" count="$BOOT_SECTORS" 2>/dev/null
dd if="$IMG" of="$TMPDIR/root.ext4" bs=512 skip="$ROOT_START" count="$ROOT_SECTORS" 2>/dev/null

# --- Mount boot ---
mkdir -p "$TMPDIR/boot"
mount -o loop,ro "$TMPDIR/boot.fat" "$TMPDIR/boot" 2>/dev/null

echo ""
echo "[2/6] Boot partition (FAT32)"

# splash.bmp used to be asserted here but no stage installs it and no package
# ships one - it was only referenced by the inert 02-run.sh.orig - so the check
# failed on every image this repo builds, including every one CI verified. This
# is a console image: 02-run.sh sets gpu_mem=32 and strips splash_screen= from
# config.txt, so there is deliberately no boot splash to assert on.
for firmware_file in start.elf; do
    if [ -s "$TMPDIR/boot/$firmware_file" ]; then
        pass "$firmware_file exists ($(stat -c%s "$TMPDIR/boot/$firmware_file" 2>/dev/null || stat -f%z "$TMPDIR/boot/$firmware_file") bytes)"
    else
        fail "$firmware_file MISSING or empty"
    fi
done

if grep -Eq '^[[:space:]]*kernel[[:space:]]*=[[:space:]]*u-boot\.bin([[:space:]]*(#.*)?)?$' \
    "$TMPDIR/boot/config.txt" 2>/dev/null; then
    fail "config.txt: U-Boot kernel override should be removed"
else
    pass "config.txt: no U-Boot kernel override"
fi

if [ -e "$TMPDIR/boot/u-boot.bin" ]; then
    fail "u-boot.bin should be removed from boot partition"
else
    pass "u-boot.bin absent"
fi

# Check config.txt. Newer m5stack-linux-dtoverlays split the legacy
# cardputerzero-overlay into board-revision specific overlays.
CARDPUTERZERO_OVERLAYS=(
    "cardputerzero-v3-overlay"
    "cardputerzero-v5-overlay"
    "cardputerzero-overlay"
)

FOUND_CARDPUTERZERO_OVERLAY=""
for overlay in "${CARDPUTERZERO_OVERLAYS[@]}"; do
    if grep -q "dtoverlay=${overlay}" "$TMPDIR/boot/config.txt" 2>/dev/null; then
        FOUND_CARDPUTERZERO_OVERLAY="$overlay"
        break
    fi
done

if [ -n "$FOUND_CARDPUTERZERO_OVERLAY" ]; then
    pass "config.txt: dtoverlay=${FOUND_CARDPUTERZERO_OVERLAY}"
else
    fail "config.txt: missing CardputerZero dtoverlay"
fi

if grep -q "dtparam=spi=on" "$TMPDIR/boot/config.txt" 2>/dev/null; then
    pass "config.txt: dtparam=spi=on"
else
    fail "config.txt: missing dtparam=spi=on"
fi

if grep -q "dtparam=i2c_arm=on" "$TMPDIR/boot/config.txt" 2>/dev/null; then
    pass "config.txt: dtparam=i2c_arm=on"
else
    fail "config.txt: missing dtparam=i2c_arm=on"
fi


# Check overlay dtbo
FOUND_CARDPUTERZERO_DTBO=""
for overlay in "${CARDPUTERZERO_OVERLAYS[@]}"; do
    dtbo="$TMPDIR/boot/overlays/${overlay}.dtbo"
    if [ -f "$dtbo" ]; then
        FOUND_CARDPUTERZERO_DTBO="$dtbo"
        break
    fi
done

if [ -n "$FOUND_CARDPUTERZERO_DTBO" ]; then
    pass "overlays/$(basename "$FOUND_CARDPUTERZERO_DTBO") exists ($(stat -c%s "$FOUND_CARDPUTERZERO_DTBO" 2>/dev/null || stat -f%z "$FOUND_CARDPUTERZERO_DTBO") bytes)"
else
    fail "CardputerZero overlay dtbo MISSING"
fi

# Check cmdline.txt
if awk '
{
    for (i = 1; i <= NF; i++) {
        if ($i == "quiet") {
            ok = 1
            break
        }
    }
}
END {
    exit (ok ? 0 : 1)
}
' "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    pass "cmdline.txt: quiet present"
else
    fail "cmdline.txt: quiet missing"
fi

if awk '
{
    for (i = 1; i <= NF; i++) {
        if ($i == "splash") {
            ok = 1
            break
        }
    }
}
END {
    exit (ok ? 0 : 1)
}
' "$TMPDIR/boot/cmdline.txt" >/dev/null 2>&1; then
    fail "cmdline.txt: splash should be removed for CardputerZero"
else
    pass "cmdline.txt: splash removed"
fi

if grep -q "plymouth.ignore-serial-consoles" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    fail "cmdline.txt: plymouth.ignore-serial-consoles should be removed for CardputerZero"
else
    pass "cmdline.txt: plymouth.ignore-serial-consoles removed"
fi

if grep -q "console=serial0,115200" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    fail "cmdline.txt: console=serial0,115200 should be removed for CardputerZero"
else
    pass "cmdline.txt: console=serial0,115200 removed"
fi

umount "$TMPDIR/boot" 2>/dev/null || true

echo ""
echo "[3/6] Kernel modules (/lib/modules/*/extra/)"

REQUIRED_MODULES=(
    "bq27xxx_battery.ko"  
    "bq27xxx_battery_i2c.ko"
    "m5ioe1.ko"
    "tca8418_keypad_m5stack.ko"
    "es8389_m5stack.ko"
    "pwm_bl_m5stack.ko"
    "st7789v_m5stack.ko"
)

for mod in "${REQUIRED_MODULES[@]}"; do
    if debugfs -R "ls lib/modules" "$TMPDIR/root.ext4" 2>/dev/null | grep -q .; then
        KVER=$(debugfs -R "ls lib/modules" "$TMPDIR/root.ext4" 2>/dev/null | grep -o '[0-9][^ ]*rpi-v8')
        # debugfs stat prints TWO lines containing "Size:" - the inode line and a
        # trailing "Fragment:  Address: 0    Number: 0    Size: 0". Taking field 2
        # of every match concatenated them into "0\nAddress:", so every module
        # reported a nonsense size and a 0-byte module looked identical to a
        # healthy one. Take the field after the first "Size:" token instead.
        SIZE=$(debugfs -R "stat lib/modules/${KVER}/extra/${mod}" "$TMPDIR/root.ext4" 2>/dev/null \
            | awk '/Size:/{for(i=1;i<=NF;i++) if($i=="Size:"){print $(i+1); exit}}')
        if [ -n "$SIZE" ]; then
            pass "$mod ($SIZE bytes)"
        else
            fail "$mod MISSING"
        fi
    fi
done

DTOVERLAYS_COMMIT=$(debugfs -R "cat etc/cardputerzero-dtoverlays.commit" \
    "$TMPDIR/root.ext4" 2>/dev/null | tr -d '\r\n' || true)
if [[ "$DTOVERLAYS_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    pass "dtoverlays source commit recorded ($DTOVERLAYS_COMMIT)"
else
    fail "dtoverlays source commit MISSING or invalid"
fi

echo ""
echo "[4/6] APPLaunch (retired desktop stack - absence only)"

# The APPLaunch binary and its user service belonged to the desktop image design
# in docs/CARDPUTERZERO-IMAGE-DESIGN.md, retired in favour of this console image.
# No live stage script installs them - only the inert 02-run.sh.orig does - so
# asserting their presence failed every build, for both the desktop and lite CI
# variants. The "not enabled" checks below are kept: they still catch an APPLaunch
# unit being wired into a target if the desktop stack is ever restored.
if debugfs -R "ls etc/systemd/user/default.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "APPLaunch"; then
    fail "APPLaunch user service enabled by default"
else
    pass "APPLaunch user service not enabled by default"
fi

if debugfs -R "ls etc/systemd/system/multi-user.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "APPLaunch"; then
    fail "APPLaunch system service enabled by default"
else
    pass "APPLaunch system service not enabled by default"
fi

echo ""
echo "[5/6] Modprobe configuration"

if debugfs -R "cat etc/modules-load.d/cardputerzero.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "i2c-dev"; then
    pass "modules-load.d: i2c-dev"
else
    fail "modules-load.d: i2c-dev MISSING"
fi

if debugfs -R "cat etc/modprobe.d/blacklist-8192cu.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "blacklist 8192cu"; then
    pass "modprobe.d: blacklist 8192cu"
else
    fail "modprobe.d: blacklist 8192cu MISSING"
fi

if debugfs -R "cat etc/modprobe.d/rfkill_default.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "rfkill"; then
    pass "modprobe.d: rfkill default_state=0"
else
    fail "modprobe.d: rfkill MISSING"
fi

echo ""
echo "[6/6] Packages"

set +e
debugfs -R "cat var/lib/dpkg/status" "$TMPDIR/root.ext4" > "$TMPDIR/dpkg_status" 2>/dev/null
echo "  dpkg_status size: $(wc -c < "$TMPDIR/dpkg_status") bytes"

# applaunch, fastfetch and cmatrix belonged to the retired desktop image and are
# installed by no live stage script - fastfetch and cmatrix survive only in the
# inert 00-packages.orig - so asserting them failed every build. Assert instead
# what this console image really declares, taken from the live 00-packages files
# and confirmed installed on a 234d54f card.
REQUIRED_PACKAGES=(i2c-tools evtest cloud-guest-utils cmus ir-keytable iw \
                   ncurses-term newsboat rpicam-apps-core rpicam-apps-encoder \
                   tmux v4l-utils fonts-dejavu-core)
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if grep -q "^Package: ${pkg}\$" "$TMPDIR/dpkg_status"; then
        pass "$pkg installed"
    else
        fail "$pkg NOT installed, though a 00-packages file declares it"
    fi
done
set -e

echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo " ✓ ALL CHECKS PASSED"
    echo "=========================================="
    exit 0
else
    echo " ✗ $ERRORS CHECK(S) FAILED"
    echo "=========================================="
    exit 1
fi
