#!/bin/bash -e
install -D -m 0755 files/lcd-console         "${ROOTFS_DIR}/usr/local/sbin/lcd-console"
install -D -m 0644 files/lcd-console.service "${ROOTFS_DIR}/etc/systemd/system/lcd-console.service"
install -D -m 0755 files/cz-display-switch         "${ROOTFS_DIR}/usr/local/sbin/cz-display-switch"
install -D -m 0644 files/cz-display-switch.service "${ROOTFS_DIR}/etc/systemd/system/cz-display-switch.service"
install -D -m 0644 files/90-cz-display-switch.rules "${ROOTFS_DIR}/etc/udev/rules.d/90-cz-display-switch.rules"

# Stop console-setup from replacing the kernel boot font.
if [ -f "${ROOTFS_DIR}/etc/default/console-setup" ]; then
    sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/; s/^FONTSIZE=.*/FONTSIZE="6x12"/' \
  "${ROOTFS_DIR}/etc/default/console-setup"
fi

on_chroot << 'CHROOT'
systemctl disable fb_load.service
CHROOT
on_chroot << 'CHROOT'
systemctl enable lcd-console.service cz-display-switch.service
# tty2 belongs to the monitor view (cz-monitor-*), not a getty login.
systemctl disable getty@tty2.service || true
CHROOT
