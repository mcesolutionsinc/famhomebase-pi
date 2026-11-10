#!/bin/sh
# The edits to an unpacked system's files that make a ready-made image behave on a first boot (called by build-image.sh after the display's installer
# has run in it). Plain file edits: no root and no chroot, so tests/test-image-patches.sh runs them on a fake root folder.
#   sh tools/image-patches.sh ROOT_DIR [--hostname NAME]
set -u

jlog() { printf '{"ts":"%s","level":"%s","component":"image-patches","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }
die() { jlog error "$*"; exit 1; }

ROOT=${1:-}; [ -n "$ROOT" ] && [ -d "$ROOT" ] || die "usage: image-patches.sh ROOT_DIR [--hostname NAME]"
shift
HOSTNAME_WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) [ $# -ge 2 ] || die "--hostname needs a name"; HOSTNAME_WANT=$2; shift ;;
    *) die "unknown option $1" ;;
  esac
  shift
done

UNITS="$ROOT/etc/systemd/system"
LIB="$ROOT/usr/local/lib/famhomebase"

# the release must carry the first-boot loader (or the saved display image would sit unused in the image) and the boot-drive settings step (or
# a staging file on the boot drive would do nothing): 0.5.10 or later
[ -f "$LIB/load-image.sh" ] && [ -f "$UNITS/famhomebase-image-load.service" ] \
  || die "this release has no first-boot image loader (famhomebase-image-load.service): the image build needs a release 0.5.10 or later"
[ -f "$LIB/bootconfig.sh" ] && [ -f "$UNITS/famhomebase-bootconfig.service" ] \
  || die "this release has no boot-drive settings step (famhomebase-bootconfig.service): the image build needs a release 0.5.10 or later"

# the machine's name: /etc/hosts must know it too, or sudo and others stall on a name they cannot resolve
if [ -n "$HOSTNAME_WANT" ]; then
  echo "$HOSTNAME_WANT" > "$ROOT/etc/hostname"
  if grep -q '^127.0.1.1' "$ROOT/etc/hosts" 2>/dev/null; then
    sed -i "s/^127.0.1.1.*/127.0.1.1\t$HOSTNAME_WANT/" "$ROOT/etc/hosts"
  else
    printf '127.0.1.1\t%s\n' "$HOSTNAME_WANT" >> "$ROOT/etc/hosts"
  fi
fi

# the base system's first-boot question ("rename the user?", userconfig.service, on its own terminal) has no place on a display, and it holds the
# boot at that point until someone answers (cloud-init's last stage waits for the boot to finish): switched off (what `systemctl mask` does)
mkdir -p "$UNITS"
ln -sf /dev/null "$UNITS/userconfig.service"

# the login prompt on the first terminal. The release's kiosk unit may say Conflicts=getty@tty1: on a first boot the user step (Pi OS's userconf,
# run by cloud-init) starts that prompt, which cancelled the kiosk's waiting start (no display until a power cycle). So the kiosk unit loses
# the Conflicts line and stops the prompt itself when it starts (host-setup.sh writes it that way from the next release), and the prompt is a
# do-nothing service, so that userconf can start it without a login appearing (masking it made userconf fail: no password, no key)
KUNIT="$UNITS/famhomebase-kiosk.service"
[ -f "$KUNIT" ] || die "the kiosk unit is not in the image"
sed -i '/^Conflicts=getty@tty1.service/d' "$KUNIT"
grep -q '^ExecStartPre=-+/bin/systemctl stop getty@tty1.service' "$KUNIT" \
  || sed -i '/^ExecStart=\/usr\/bin\/cage/i ExecStartPre=-+/bin/systemctl stop getty@tty1.service' "$KUNIT"
grep -q '^ExecStartPre=-+/bin/systemctl stop getty@tty1.service' "$KUNIT" && ! grep -q '^Conflicts=getty@tty1' "$KUNIT" \
  || die "could not change the kiosk unit: its ExecStart line is not the one this script knows"
mkdir -p "$UNITS/getty@tty1.service.d"
printf '[Service]\nType=simple\nExecStartPre=\nExecStart=\nExecStart=/bin/sleep infinity\nStandardInput=null\nTTYReset=no\nTTYVHangup=no\nTTYVTDisallocate=no\n' \
  > "$UNITS/getty@tty1.service.d/10-noop.conf"

# SSH host keys: the base makes them only when systemd says "first boot", which was not true on the test card ("no hostkeys available").
# Make sure they exist whenever SSH starts, before the unit's own `sshd -t` check (each device makes its own; none are baked in)
mkdir -p "$UNITS/ssh.service.d"
printf '[Service]\nExecStartPre=\nExecStartPre=/usr/bin/ssh-keygen -A\nExecStartPre=/usr/sbin/sshd -t\n' > "$UNITS/ssh.service.d/famhomebase-hostkeys.conf"
rm -f "$ROOT"/etc/ssh/ssh_host_*

jlog info "image edits done"
