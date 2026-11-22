#!/bin/bash -e
# cz-firstboot replaces the stock first-boot prompt. Neutralise it with an
# ExecStart override rather than masking, so Wants=/After= stay satisfiable.
install -d "${ROOTFS_DIR}/etc/systemd/system/userconfig.service.d"
printf '[Service]\nExecStart=\nExecStart=/bin/true\n' \
  > "${ROOTFS_DIR}/etc/systemd/system/userconfig.service.d/10-cz-replaced.conf"
chmod 644 "${ROOTFS_DIR}/etc/systemd/system/userconfig.service.d/10-cz-replaced.conf"

# 01-user-rename hands tty1 to the stock prompt and expects it to restore
# getty. cz-firstboot does not, so enable getty explicitly here.
on_chroot << 'CHROOT'
systemctl enable getty@tty1.service
CHROOT
