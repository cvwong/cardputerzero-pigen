#!/bin/bash -e

# Compile and install CardputerZero kernel modules + overlay
install -d -m 0755 "${ROOTFS_DIR}/opt"
# The upstream config_setup target otherwise downloads this unpinned Gist.
install -m 0755 files/rpi-config.py "${ROOTFS_DIR}/opt/rpi-config.py"

on_chroot << 'CHROOT'
set -e

# Install build dependencies
# stage0 downloaded but did not install the headers. Install the VERSIONED
# headers package (linux-headers-<KVER>), NOT the meta-package linux-headers-rpi-v8
# which apt resolves to the repo's newer conflicting version.
KVER=$(ls /lib/modules/ | grep rpi-v8 | head -1)
if [ ! -d "/lib/modules/${KVER}/build" ] && [ ! -L "/lib/modules/${KVER}/build" ]; then
    echo "Installing headers for kernel ${KVER}..."
    apt-get install -y --no-install-recommends "linux-headers-${KVER}" || {
        echo "ERROR: apt could not install linux-headers-${KVER}"
        echo "Searching for cached .deb files..."
        find / -maxdepth 4 -name "linux-headers-${KVER}*.deb" 2>/dev/null
        exit 1
    }
fi

apt-get install -y --no-install-recommends \
    build-essential \
    device-tree-compiler \
    git

# Re-hold kernel packages to prevent accidental upgrades
apt-mark hold linux-base-rpi-v8 linux-image-rpi-v8 || true

# Always build the latest driver from the main branch.
rm -rf /tmp/dtoverlays
git clone --depth=1 https://github.com/m5stack/m5stack-linux-dtoverlays.git \
    /tmp/dtoverlays
git -C /tmp/dtoverlays rev-parse HEAD \
    > /etc/cardputerzero-dtoverlays.commit

KVER=$(ls /lib/modules/ | grep rpi-v8 | head -1)
export KERNELDIR="/lib/modules/${KVER}/build"
export EXTRADIR="/lib/modules/${KVER}/extra"

# make and install st7789v overlay + module
cd /tmp/dtoverlays/modules/CardputerZero
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y install
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y config_setup

# Reserve 64 MiB of contiguous memory for the KMS display driver.
DEFAULT_CONFIG="/boot/firmware/config.txt"
sed -i 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,cma-64/' "$DEFAULT_CONFIG"

# Update module dependencies
depmod -a "${KVER}"

# Clean up build artifacts only (keep all build tools for user driver builds)
rm -rf /tmp/dtoverlays

CHROOT
install -D -m 0755 files/cz-font "${ROOTFS_DIR}/usr/local/bin/cz-font"
