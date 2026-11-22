#!/bin/bash -e
# Late size trim. Runs after stage 05 has compiled the st7789v display module,
# so the build toolchain / kernel headers are no longer needed in the image.
on_chroot << 'EOF'
# Drop orphaned dependencies of the purged toolchain (gcc/g++/cpp/make/libc-dev...)
apt-get autoremove --purge -y

# Kernel headers were only needed to build the stage-05 display module.
dpkg-query -W -f='${Package}\n' 'linux-headers-*' 2>/dev/null | xargs -r apt-get purge -y || true
apt-get autoremove --purge -y

# Keep only the configured locale (en_US); /usr/share/locale is ~180MB otherwise.
for d in /usr/share/locale/*; do
  case "$(basename "$d")" in
    en_US|en) ;;
    *) rm -rf "$d" ;;
  esac
done

# Drop man pages and doc bodies, but retain copyright notices.
rm -rf /usr/share/man/*
find /usr/share/doc -type f ! -name copyright -delete 2>/dev/null || true
find /usr/share/doc -depth -type d -empty -delete 2>/dev/null || true

apt-get clean
EOF
on_chroot << 'CHROOT'
# Protect the kernel and networking from autoremove.
dpkg-query -W -f='${Package}\n' 'linux-image*' 'linux-modules*' \
    'network-manager*' 'wpasupplicant*' 'netplan*' 2>/dev/null | xargs -r apt-mark manual
# Headers were only needed to build the panel module in stage 05.
apt-mark showhold | grep '^linux-headers' | xargs -r apt-mark unhold
P=$(dpkg-query -W -f='${Package}\n' 'linux-headers*' 2>/dev/null || true)
if [ -n "$P" ]; then apt-get purge -y $P; fi
# populate_database in export-image/05-finalise fetches a changelog per package.
apt-get purge -y apt-listchanges || true
apt-get autoremove --purge -y
CHROOT
