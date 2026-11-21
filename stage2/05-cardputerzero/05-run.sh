#!/bin/bash -e
install -D -m 0755 files/lcd-console         "${ROOTFS_DIR}/usr/local/sbin/lcd-console"
install -D -m 0644 files/lcd-console.service "${ROOTFS_DIR}/etc/systemd/system/lcd-console.service"

# Stop console-setup from replacing the kernel boot font.
if [ -f "${ROOTFS_DIR}/etc/default/console-setup" ]; then
    sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/; s/^FONTSIZE=.*/FONTSIZE="6x12"/' \
  "${ROOTFS_DIR}/etc/default/console-setup"
fi

on_chroot << 'CHROOT'
systemctl disable fb_load.service
CHROOT
on_chroot << 'CHROOT'
systemctl enable lcd-console.service
CHROOT
