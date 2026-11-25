#!/bin/bash -e
install -D -m 0755 files/cz-status        "${ROOTFS_DIR}/usr/local/bin/cz-status"
install -D -m 0755 files/cz-net           "${ROOTFS_DIR}/usr/local/bin/cz-net"
install -D -m 0755 files/cz-camera-present "${ROOTFS_DIR}/usr/local/bin/cz-camera-present"
install -D -m 0755 files/cz               "${ROOTFS_DIR}/usr/local/bin/cz"
install -D -m 0644 files/cz-tmux.conf     "${ROOTFS_DIR}/etc/cz-tmux.conf"
install -D -m 0644 files/cz-autostart.sh  "${ROOTFS_DIR}/etc/profile.d/cz-autostart.sh"
install -D -m 0644 files/99-quiet-console.conf "${ROOTFS_DIR}/etc/sysctl.d/99-quiet-console.conf"
install -d "${ROOTFS_DIR}/etc/cloud"
touch "${ROOTFS_DIR}/etc/cloud/cloud-init.disabled"
install -D -m 0644 files/10-cz-issue.conf \
  "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/10-cz-issue.conf"
# Regenerates /etc/issue as a bordered box before each login prompt. The static
# files/issue.cz installed below is the fallback, visible only if this fails.
# There is deliberately no NetworkManager hook to repaint the banner once DHCP
# completes: getty starts ~17s before the lease arrives, and restarting it to
# refresh the box clears the screen and discards a half-typed username.
install -D -m 0755 files/cz-issue "${ROOTFS_DIR}/usr/local/sbin/cz-issue"
install -D -m 0644 files/cz-motd.sh "${ROOTFS_DIR}/etc/profile.d/cz-motd.sh"
install -D -m 0644 files/issue.net "${ROOTFS_DIR}/etc/issue.net"
install -D -m 0644 files/motd      "${ROOTFS_DIR}/etc/motd"
sed -i 's|^#\?Banner.*|Banner /etc/issue.net|' "${ROOTFS_DIR}/etc/ssh/sshd_config"
if [ -d "${ROOTFS_DIR}/etc/update-motd.d" ]; then
    chmod -x "${ROOTFS_DIR}"/etc/update-motd.d/* 2>/dev/null || true
fi
install -D -m 0644 files/tca8418_keypad_m5stack_keymap.map \
  "${ROOTFS_DIR}/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map"
install -D -m 0755 files/cz-keymap "${ROOTFS_DIR}/usr/local/sbin/cz-keymap"
install -D -m 0644 files/cz-console-switch.map "${ROOTFS_DIR}/usr/share/keymaps/cz-console-switch.map"
install -D -m 0644 files/cz-keymap.service "${ROOTFS_DIR}/etc/systemd/system/cz-keymap.service"
on_chroot << 'CHROOT'
systemctl enable cz-keymap.service
CHROOT
install -D -m 0644 files/issue.cz "${ROOTFS_DIR}/etc/issue"
install -D -m 0644 files/asound.conf "${ROOTFS_DIR}/etc/asound.conf"
# Shared 53x14 theme (palette, box drawing, hdr/row helpers) sourced by both
# cz-menu-theme, cz-record and cz-files, so it must be in place before they run.
install -D -m 0644 files/cz-theme.sh  "${ROOTFS_DIR}/usr/local/lib/cz-theme.sh"
install -D -m 0755 files/cz-menu "${ROOTFS_DIR}/usr/local/bin/cz-menu"
install -D -m 0755 files/cz-menu-theme "${ROOTFS_DIR}/usr/local/bin/cz-menu-theme"
install -D -m 0755 files/cz-ir "${ROOTFS_DIR}/usr/local/bin/cz-ir"
install -D -m 0755 files/cz-record "${ROOTFS_DIR}/usr/local/bin/cz-record"
# File transfer web UI. The server lives in /usr/local/lib next to the theme
# because cz-files launches it as a child rather than putting it on PATH.
install -D -m 0755 files/cz-files "${ROOTFS_DIR}/usr/local/bin/cz-files"
install -D -m 0755 files/cz-files-web.py "${ROOTFS_DIR}/usr/local/lib/cz-files-web.py"
install -D -m 0755 files/cz-font "${ROOTFS_DIR}/usr/local/bin/cz-font"
install -D -m 0755 files/cz-output "${ROOTFS_DIR}/usr/local/bin/cz-output"
install -D -m 0755 files/cz-monitor-session "${ROOTFS_DIR}/usr/local/bin/cz-monitor-session"
install -D -m 0755 files/cz-cage-watcher "${ROOTFS_DIR}/usr/local/sbin/cz-cage-watcher"
install -D -m 0644 files/cz-cage.service "${ROOTFS_DIR}/etc/systemd/system/cz-cage.service"
install -D -m 0644 files/cz-cage-watcher.service "${ROOTFS_DIR}/etc/systemd/system/cz-cage-watcher.service"
install -D -m 0644 files/foot.ini "${ROOTFS_DIR}/etc/foot/foot.ini"
# Cached rootfses keep files from earlier builds; the frozen-frame monitor
# stack was retired in 0494215, so remove it explicitly.
rm -f "${ROOTFS_DIR}/usr/local/sbin/cz-monitor-view" \
      "${ROOTFS_DIR}/usr/local/sbin/cz-monitor-repaint" \
      "${ROOTFS_DIR}/usr/local/bin/cz-monitor-shell" \
      "${ROOTFS_DIR}/etc/systemd/system/cz-monitor-view.service" \
      "${ROOTFS_DIR}/etc/systemd/system/cz-monitor-tty2.service" \
      "${ROOTFS_DIR}/etc/systemd/system/cz-monitor-repaint.service" \
      "${ROOTFS_DIR}/etc/systemd/system/cz-monitor-repaint.path" \
      "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/cz-monitor-view.service" \
      "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/cz-monitor-tty2.service" \
      "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/cz-monitor-repaint.path"
HN=$(cat "${ROOTFS_DIR}/etc/hostname")
sed -i '/^127\.0\.1\.1[[:space:]]/d' "${ROOTFS_DIR}/etc/hosts"
printf '127.0.1.1\t%s\n' "$HN" >> "${ROOTFS_DIR}/etc/hosts"
install -D -m 0755 files/cz-camera "${ROOTFS_DIR}/usr/local/bin/cz-camera"
install -D -m 0644 files/Camera_1.0.4_m5stack1_arm64.deb "${ROOTFS_DIR}/tmp/camera.deb"
on_chroot << 'CHROOT'
apt-get install -y /tmp/camera.deb
rm -f /tmp/camera.deb
CHROOT
install -D -m 0755 files/cz-news          "${ROOTFS_DIR}/usr/local/bin/cz-news"
install -D -m 0644 files/newsboat-urls    "${ROOTFS_DIR}/usr/share/cz/newsboat-urls"
install -D -m 0644 files/newsboat-config  "${ROOTFS_DIR}/usr/share/cz/newsboat-config"
install -D -m 0755 files/cz-wifi "${ROOTFS_DIR}/usr/local/bin/cz-wifi"
install -D -m 0755 files/cz-hostname "${ROOTFS_DIR}/usr/local/bin/cz-hostname"
install -D -m 0755 files/cz-splash "${ROOTFS_DIR}/usr/local/bin/cz-splash"
install -D -m 0755 files/cz-firstboot "${ROOTFS_DIR}/usr/local/bin/cz-firstboot"
install -D -m 0644 files/cz-splash.rgb565 "${ROOTFS_DIR}/usr/share/cz/cz-splash.rgb565"
install -D -m 0644 files/cz-ping.wav "${ROOTFS_DIR}/usr/share/cz/cz-ping.wav"
install -D -m 0644 files/cz-splash.service "${ROOTFS_DIR}/etc/systemd/system/cz-splash.service"
install -D -m 0644 files/cz-firstboot.service "${ROOTFS_DIR}/etc/systemd/system/cz-firstboot.service"
on_chroot << 'CHROOT'
systemctl enable cz-splash.service
systemctl enable cz-firstboot.service
systemctl enable seatd.service cz-cage-watcher.service
CHROOT
