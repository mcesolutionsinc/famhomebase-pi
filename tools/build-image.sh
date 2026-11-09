#!/bin/sh
# Builds a ready-made FamHomeBase display system image (F0 of docs/plans/famhomebase-pi-image-plan.md): the official Raspberry Pi OS Lite
# (Debian 13, 64-bit) with the display installed in it by the real installer (install.sh --kiosk --no-start) and the display's Docker image
# saved inside it, so a first boot starts the display at once. Imager's customisation (Wi-Fi, hostname, user, SSH key) is applied by the
# base system's own first-boot step, as for any Raspberry Pi OS image.
#
#   sudo sh tools/build-image.sh --version 0.5.6 [--env prod|staging] [--out DIR] [--no-compress]
#
# Needs: root, `mount` and loop devices (a Linux machine or a CI runner, not a container), a 64-bit ARM machine (it runs the image's own
# programs in a chroot, with no emulation), docker (to save the display's image), curl, xz, parted and e2fsprogs. Nothing is published.
#   --version X.Y.Z   the release to put in (its install.sh and its display image must exist)
#   --env NAME        prod (default) or staging: where the display looks for the cloud
#   --out DIR         where the finished image goes (default ./dist)
#   --base-image FILE a Raspberry Pi OS Lite .img.xz you already have (default: download the newest official one)
#   --extra-mb N      room to add to the base system's root partition for what is installed (default 3072)
#   --no-compress     leave the .img as it is (faster to try; about 4 GB)
#   --test-key FILE   TEST IMAGES ONLY: add the user `famhomebase` with this SSH public key, passwordless sudo and SSH switched on, so a test
#                     card can be reached without Imager's first-boot settings. The file name gets "-TEST" in it: never publish such an image.
#   --test-password-file FILE   with --test-key: also give that user the password in this file (first line)
#   --hostname NAME   the machine's name (default: the base system's)
set -eu

REPO="${FAMHOMEBASE_REPO:-mcesolutionsinc/famhomebase-pi}"
DL="${GITHUB_DOWNLOAD:-https://github.com}"
BASE_URL="${FAMHOMEBASE_BASE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}"
IMAGE_NAME="${FAMHOMEBASE_IMAGE:-ghcr.io/mcesolutionsinc/famhomebase-pi}"
VERSION=""; ENVNAME=prod; OUT=dist; BASE=""; EXTRA=3072; COMPRESS=1; TEST_KEY=""; TEST_PW=""; HOSTNAME_WANT=""

jlog() { printf '{"ts":"%s","level":"%s","component":"build-image","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }
die() { jlog error "$*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a number like 0.5.6"; VERSION=${2#v}; shift ;;
    --env) [ $# -ge 2 ] || die "--env needs prod or staging"; ENVNAME=$2; shift ;;
    --out) [ $# -ge 2 ] && [ -n "$2" ] || die "--out needs a folder"; OUT=$2; shift ;;
    --base-image) [ $# -ge 2 ] && [ -f "$2" ] || die "--base-image needs an existing .img.xz file"; BASE=$2; shift ;;
    --extra-mb) [ $# -ge 2 ] || die "--extra-mb needs a number"; EXTRA=$2; shift ;;
    --no-compress) COMPRESS=0 ;;
    --test-key) [ $# -ge 2 ] && [ -f "$2" ] || die "--test-key needs an existing SSH public key file"; TEST_KEY=$2; shift ;;
    --test-password-file) [ $# -ge 2 ] && [ -f "$2" ] || die "--test-password-file needs an existing file"; TEST_PW=$2; shift ;;
    --hostname) [ $# -ge 2 ] || die "--hostname needs a name"; HOSTNAME_WANT=$2; shift ;;
    -h|--help) sed -n '2,/^set /{/^set /!p}' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "--version is required and must look like 0.5.6 (got '$VERSION')"
case "$ENVNAME" in prod|staging) ;; *) die "'$ENVNAME' is not an environment: use prod or staging" ;; esac
[ -z "$TEST_PW" ] || [ -n "$TEST_KEY" ] || die "--test-password-file only goes with --test-key"
[ -z "$HOSTNAME_WANT" ] || echo "$HOSTNAME_WANT" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' || die "'$HOSTNAME_WANT' is not a host name (letters, digits and dashes)"
case "$EXTRA" in ''|*[!0-9]*) die "--extra-mb must be a whole number" ;; esac
[ "$(${FAMHOMEBASE_UNAME:-uname} -m)" = aarch64 ] || [ -n "${FAMHOMEBASE_ANY_ARCH:-}" ] || die "this needs a 64-bit ARM machine (it runs the image's own programs); on another machine set up qemu-user-static and FAMHOMEBASE_ANY_ARCH=1"
[ "$(id -u)" -eq 0 ] || [ -n "${FAMHOMEBASE_NO_ROOT:-}" ] || die "this mounts disk images, so it needs root: run it with sudo"
for tool in curl xz parted losetup mount umount chroot e2fsck resize2fs docker gzip; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not installed"
done
[ -n "${FAMHOMEBASE_DRY_RUN:-}" ] && { jlog info "arguments are fine (dry run): version $VERSION, env $ENVNAME, out $OUT"; exit 0; }

WORK=$(mktemp -d /var/tmp/famhomebase-image.XXXXXX)
ROOT="$WORK/root"; DEV=""
cleanup() {
  set +e
  for m in dev/pts dev proc sys boot/firmware ""; do umount "$ROOT${m:+/$m}" 2>/dev/null || umount -l "$ROOT${m:+/$m}" 2>/dev/null; done
  [ -n "$DEV" ] && losetup -d "$DEV" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

IMG="$WORK/base.img"
if [ -n "$BASE" ]; then
  jlog info "unpacking $BASE"; xz -dc "$BASE" > "$IMG" || die "could not unpack $BASE"
else
  jlog info "downloading the official Raspberry Pi OS Lite (64-bit)"
  curl -fsSL -o "$WORK/base.img.xz" "$BASE_URL" || die "could not download $BASE_URL"
  xz -dc "$WORK/base.img.xz" > "$IMG" || die "could not unpack the download"; rm -f "$WORK/base.img.xz"
fi

# room for what is installed: grow the file and the second (root) partition, then the file system in it
parted -s "$IMG" print 2>/dev/null | grep -q 'Partition Table: msdos' || die "the base image does not have an MBR partition table (the build expects the two-partition Raspberry Pi OS layout)"
truncate -s "+${EXTRA}M" "$IMG"
parted -s "$IMG" resizepart 2 100% || die "could not grow the root partition"
DEV=$(losetup -fP --show "$IMG") || die "no loop device available: this needs a real Linux machine or runner, not a container"
e2fsck -fy "${DEV}p2" >/dev/null 2>&1 || true
resize2fs "${DEV}p2" >/dev/null 2>&1 || die "could not grow the root file system"

mkdir -p "$ROOT"; mount "${DEV}p2" "$ROOT"; mkdir -p "$ROOT/boot/firmware"; mount "${DEV}p1" "$ROOT/boot/firmware"
mount --bind /dev "$ROOT/dev"; mount -t devpts devpts "$ROOT/dev/pts" 2>/dev/null || mount --bind /dev/pts "$ROOT/dev/pts"
mount -t proc proc "$ROOT/proc"; mount -t sysfs sysfs "$ROOT/sys"

# the chroot needs a network and must not start services (the base system is not running)
[ -e "$ROOT/etc/resolv.conf" ] || [ -L "$ROOT/etc/resolv.conf" ] && mv "$ROOT/etc/resolv.conf" "$ROOT/etc/resolv.conf.orig"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"; chmod +x "$ROOT/usr/sbin/policy-rc.d"

# a build machine on Wi-Fi drops now and then: apt retries patiently (removed again at the end, so the image keeps the base system's settings)
printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\n' > "$ROOT/etc/apt/apt.conf.d/99famhomebase-build"

jlog info "installing Docker and the display $VERSION ($ENVNAME) into the image"
curl -fsSL -o "$ROOT/tmp/install.sh" "$DL/$REPO/releases/download/v$VERSION/install.sh" || die "could not download install.sh of release $VERSION"
chroot "$ROOT" /bin/sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get install -y -q --no-install-recommends curl ca-certificates docker.io docker-cli && systemctl enable docker.service" || die "could not install Docker in the image"
chroot "$ROOT" /bin/sh /tmp/install.sh --version "$VERSION" --env "$ENVNAME" --kiosk --no-start || die "the display's installer failed in the image"
rm -f "$ROOT/tmp/install.sh"

# a test image only: a user, its key and SSH, so the card can be reached without first-boot settings
if [ -n "$TEST_KEY" ]; then
  jlog warn "adding the test user famhomebase with a key and SSH to the image: for testing only, never publish this image"
  chroot "$ROOT" /bin/sh -c "id famhomebase >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,video,render,input,netdev,plugdev famhomebase" || die "could not add the test user"
  if [ -n "$TEST_PW" ]; then printf 'famhomebase:%s\n' "$(head -n 1 "$TEST_PW")" | chroot "$ROOT" chpasswd || die "could not set the test user's password"; fi
  mkdir -p "$ROOT/home/famhomebase/.ssh"; cp "$TEST_KEY" "$ROOT/home/famhomebase/.ssh/authorized_keys"
  chroot "$ROOT" /bin/sh -c "chown -R famhomebase:famhomebase /home/famhomebase/.ssh && chmod 700 /home/famhomebase/.ssh && chmod 600 /home/famhomebase/.ssh/authorized_keys && systemctl enable ssh.service" || die "could not set up SSH for the test user"
  printf 'famhomebase ALL=(ALL) NOPASSWD:ALL\n' > "$ROOT/etc/sudoers.d/90-famhomebase-test"; chmod 440 "$ROOT/etc/sudoers.d/90-famhomebase-test"
  # a report on the card's boot drive (readable on any computer, no network needed), written 90 s and 240 s after boot: what cloud-init did,
  # whether SSH is up and why not, what is listening, what failed. For finding out why a test card cannot be reached.
  cat > "$ROOT/usr/local/lib/famhomebase/test-report.sh" <<'REPORT_EOF'
#!/bin/sh
OUT=/boot/firmware/famhomebase-test-report.txt
for wait in 90 150; do
  sleep "$wait"
  {
    echo "== $(date -u +%FT%TZ) up $(cut -d' ' -f1 /proc/uptime)s host $(hostname)"; ip -br a; echo
    echo "== cloud-init"; cloud-init status --long 2>&1; echo
    echo "== failed units"; systemctl --failed --no-pager 2>&1; echo
    echo "== active"; systemctl is-active ssh.service ssh.socket sshd-keygen.service userconfig.service cloud-final.service docker famhomebase famhomebase-kiosk famhomebase-image-load 2>&1 | paste -sd' '; echo
    echo "== listening"; ss -ltn 2>&1; echo
    echo "== ssh journal"; journalctl -b -u ssh -u ssh.socket -u sshd-keygen --no-pager 2>&1 | tail -30; echo
    echo "== cloud-init warnings and errors"; grep -iE "warn|error|fail|invalid|schema" /var/log/cloud-init.log 2>&1 | tail -30; echo
    echo "== boot drive files"; ls -la /boot/firmware | grep -iE "user-data|meta-data|network|ssh|famhomebase"; echo
    echo "== display"; famhomebase status 2>&1 | head -8
  } > "$OUT.new" 2>&1 && mv "$OUT.new" "$OUT"
done
REPORT_EOF
  printf '[Unit]\nDescription=FamHomeBase test image: write a report on the boot drive\n\n[Service]\nType=simple\nExecStart=/bin/sh /usr/local/lib/famhomebase/test-report.sh\n\n[Install]\nWantedBy=multi-user.target\n' > "$ROOT/etc/systemd/system/famhomebase-test-report.service"
  chroot "$ROOT" /bin/sh -c "systemctl enable famhomebase-test-report.service" || die "could not enable the test report"
fi
[ -z "$HOSTNAME_WANT" ] || { echo "$HOSTNAME_WANT" > "$ROOT/etc/hostname"; sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME_WANT/" "$ROOT/etc/hosts"; }

# the base system's first-boot question ("rename the user?", userconfig.service, on its own terminal) has no place on a display, and it holds the
# boot at that point until someone answers (cloud-init's last stage waits for the boot to finish): switched off
chroot "$ROOT" /bin/sh -c "systemctl mask userconfig.service" || die "could not switch off the first-boot user question"

# the display's own image, saved inside (loaded once at first boot by famhomebase-image-load.service)
jlog info "saving the display image $IMAGE_NAME:$VERSION inside the image"
docker pull "$IMAGE_NAME:$VERSION" >/dev/null || die "could not pull $IMAGE_NAME:$VERSION (is the release's image published and public?)"
mkdir -p "$ROOT/var/lib/famhomebase"
docker save "$IMAGE_NAME:$VERSION" | gzip -1 > "$ROOT/var/lib/famhomebase/image.tar.gz" || die "could not save the display image"

# tidy: nothing of the build stays in the image
chroot "$ROOT" /bin/sh -c "apt-get clean && rm -rf /var/lib/apt/lists/* /var/log/apt/* /tmp/* ; : > /etc/machine-id" || true
rm -f "$ROOT/usr/sbin/policy-rc.d" "$ROOT/etc/resolv.conf" "$ROOT/etc/apt/apt.conf.d/99famhomebase-build"
[ -e "$ROOT/etc/resolv.conf.orig" ] || [ -L "$ROOT/etc/resolv.conf.orig" ] && mv "$ROOT/etc/resolv.conf.orig" "$ROOT/etc/resolv.conf"
sync
cleanup_mounts() { for m in dev/pts dev proc sys boot/firmware ""; do umount "$ROOT${m:+/$m}" || umount -l "$ROOT${m:+/$m}"; done; }
cleanup_mounts
e2fsck -fy "${DEV}p2" >/dev/null 2>&1 || true
# free space that still holds deleted package files is data the compressor must keep: write zeros over it first (zerofree, if installed)
if command -v zerofree >/dev/null 2>&1; then jlog info "zeroing the free space"; zerofree "${DEV}p2" || jlog warn "zerofree failed: the image will be larger"; else jlog warn "zerofree is not installed: the image will be larger (sudo apt install zerofree)"; fi
losetup -d "$DEV"; DEV=""

mkdir -p "$OUT"
FINAL="$OUT/famhomebase-$VERSION-$ENVNAME${TEST_KEY:+-TEST}-arm64.img"
mv "$IMG" "$FINAL"
if [ "$COMPRESS" -eq 1 ]; then
  jlog info "compressing (this is the slow part)"
  xz -T0 -6 -f "$FINAL" || die "could not compress the image"
  FINAL="$FINAL.xz"
fi
(cd "$OUT" && sha256sum "$(basename "$FINAL")" > "$(basename "$FINAL").sha256")
jlog info "done: $FINAL ($(du -h "$FINAL" | cut -f1))"
