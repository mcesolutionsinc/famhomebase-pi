#!/bin/sh
# FamHomeBase display for Raspberry Pi (or any 64-bit Linux with Docker and systemd): installer. Also the re-installer: running it
# again on an existing install brings it up to date and keeps your settings.
#
#   curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sudo sh -s -- --kiosk
#
# It installs like any Linux service:
#   /usr/local/lib/famhomebase/        the scripts and VERSION
#   /usr/local/bin/famhomebase         the `famhomebase` command (status, logs, update, version)
#   /etc/famhomebase/famhomebase.env   your settings (made once, never overwritten by an update)
#   /var/lib/famhomebase/              state: the saved copy for a way back, the kiosk's browser profile (holds the pairing)
#   /usr/local/share/doc/famhomebase/  README, licence, INSTALL, TROUBLESHOOTING
#   /etc/systemd/system/               famhomebase.service, famhomebase-update.service and .timer
#
# Options:
#   --version X.Y.Z  install that release instead of the newest release
#   --env NAME       prod (default) or staging; staging shows a STAGING banner and points at the staging site
#   --api-url URL    where the cloud is, https://host with no path (default: the site that goes with --env)
#   --port N         the port on this machine (default 80; it must be free). The display listens on 127.0.0.1 only.
#   --kiosk          also show the display full-screen at boot (Raspberry Pi OS desktop): turns on desktop autologin and runs the
#                    kiosk as a systemd user service
#   --user NAME      whose desktop the kiosk runs in (default: the user who ran sudo)
#   --no-start       set everything up, but don't start anything
#
# Needs Docker already installed (docs/INSTALL.md) and root (sudo). Compose is not needed: the display is one container started by systemd.
set -eu

REPO="${FAMHOMEBASE_REPO:-mcesolutionsinc/famhomebase-pi}"
API="${GITHUB_API:-https://api.github.com}"
DL="${GITHUB_DOWNLOAD:-https://github.com}"
LIB_DIR="${FAMHOMEBASE_LIB_DIR:-/usr/local/lib/famhomebase}"
DOC_DIR="${FAMHOMEBASE_DOC_DIR:-/usr/local/share/doc/famhomebase}"
ETC_DIR="${FAMHOMEBASE_ETC_DIR:-/etc/famhomebase}"
STATE_DIR="${FAMHOMEBASE_STATE_DIR:-/var/lib/famhomebase}"
ENV_FILE="$ETC_DIR/famhomebase.env"
CURL="${CURL:-curl}"
WANT=""; ENVNAME=""; API_URL=""; PORT=""; KIOSK=0; START=1; USER_NAME="${SUDO_USER:-}"

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a number like 0.1.0"; WANT=${2#v}; shift ;;
    --env) [ $# -ge 2 ] || die "--env needs prod or staging"; ENVNAME=$2; shift ;;
    --api-url) [ $# -ge 2 ] || die "--api-url needs an address like https://famhomebase.mc-esolutions.ca"; API_URL=$2; shift ;;
    --port) [ $# -ge 2 ] && [ -n "$2" ] || die "--port needs a number"; PORT=$2; shift ;;
    --user) [ $# -ge 2 ] && [ -n "$2" ] || die "--user needs a name"; USER_NAME=$2; shift ;;
    --kiosk) KIOSK=1 ;;
    --no-start) START=0 ;;
    -h|--help) sed -n '2,28p' "$0" 2>/dev/null || true; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed. $2"; }
need curl "Install it with: sudo apt install curl"
need tar "Install it with: sudo apt install tar"
need sha256sum "Install it with: sudo apt install coreutils"
need systemctl "This installer needs systemd."
[ "$(id -u)" -eq 0 ] || [ -n "${FAMHOMEBASE_NO_ROOT:-}" ] || die "this installs into /usr/local and /etc, so it needs root. Run it as: curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | sudo sh -s -- --kiosk"
need docker "Install Docker first: see https://github.com/$REPO/blob/main/docs/INSTALL.md (section 'Install Docker')"

case "$ENVNAME" in ''|prod|staging) ;; *) die "'$ENVNAME' is not an environment: use prod or staging" ;; esac
if [ -n "$API_URL" ]; then
  echo "$API_URL" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?$' || die "'$API_URL' is not an address like https://famhomebase.mc-esolutions.ca (https, a host, no path)"
fi
if [ -n "$PORT" ]; then
  echo "$PORT" | grep -Eq '^[0-9]+$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "'$PORT' is not a port number (1-65535)"
fi
if [ "$KIOSK" -eq 1 ] && { [ -z "$USER_NAME" ] || [ "$USER_NAME" = root ]; }; then
  die "--kiosk needs the name of the desktop user: run the installer with sudo from that user's login, or add --user NAME"
fi
for d in "$LIB_DIR" "$DOC_DIR" "$ETC_DIR" "$STATE_DIR"; do case "$d" in ""|"/") die "an install folder is empty or the filesystem root" ;; esac; done

if [ -z "$WANT" ]; then
  say "Looking up the newest release..."
  body=$($CURL -fsSL "$API/repos/$REPO/releases?per_page=100") || die "could not reach GitHub to find the newest release of $REPO"
  for v in $(echo "$body" | grep -o '"tag_name": *"v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' | sed 's/.*"v\([0-9.]*\)"/\1/'); do
    if [ -z "$WANT" ]; then WANT=$v; continue; fi
    # keep the higher of WANT and v (sort -V is not in every busybox: compare field by field)
    higher=$(printf '%s\n%s\n' "$WANT" "$v" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    WANT=$higher
  done
  [ -n "$WANT" ] || die "no release of $REPO was found (none published yet?)"
fi
echo "$WANT" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "'$WANT' is not a version like 0.1.0"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
name="famhomebase-pi-$WANT"
say "Downloading FamHomeBase display $WANT..."
$CURL -fsSL -o "$tmp/$name.tar.gz" "$DL/$REPO/releases/download/v$WANT/$name.tar.gz" || die "could not download release $WANT"
$CURL -fsSL -o "$tmp/$name.tar.gz.sha256" "$DL/$REPO/releases/download/v$WANT/$name.tar.gz.sha256" || die "could not download its checksum"
expected=$(cut -d' ' -f1 < "$tmp/$name.tar.gz.sha256")
actual=$(sha256sum "$tmp/$name.tar.gz" | cut -d' ' -f1)
[ -n "$expected" ] && [ "$expected" = "$actual" ] || die "checksum mismatch: the download is damaged or not what was published. Nothing was installed."
mkdir "$tmp/new" && tar --no-same-owner -xzf "$tmp/$name.tar.gz" -C "$tmp/new" || die "could not unpack release $WANT"
[ -f "$tmp/new/scripts/run.sh" ] && [ -f "$tmp/new/scripts/host-setup.sh" ] && [ "$(tr -d ' \r\n' < "$tmp/new/VERSION" 2>/dev/null)" = "$WANT" ] \
  || die "the download is not a valid $WANT release. Nothing was installed."

existing=""
[ -f "$LIB_DIR/VERSION" ] && existing=$(tr -d ' \r\n' < "$LIB_DIR/VERSION")
# the same placing the update script does (a release is scripts/, doc/, famhomebase.env.example and VERSION)
rm -rf "${LIB_DIR:?}" "${DOC_DIR:?}"
mkdir -p "$LIB_DIR" "$DOC_DIR" "$ETC_DIR" "$STATE_DIR" || die "could not make the install folders"
cp -R "$tmp/new/scripts/." "$LIB_DIR/" && cp -f "$tmp/new/VERSION" "$LIB_DIR/VERSION" || die "could not install the scripts"
[ -d "$tmp/new/doc" ] && cp -R "$tmp/new/doc/." "$DOC_DIR/"
cp -f "$tmp/new/famhomebase.env.example" "$ETC_DIR/famhomebase.env.example"
if [ -n "$existing" ]; then say "Updated $existing -> $WANT"; else say "Installed $WANT"; fi

# Settings: made once, and then only the settings you pass are changed, so your other choices survive a re-run.
set_env() { # key, value
  if grep -q "^$1=" "$ENV_FILE"; then
    sed "s|^$1=.*|$1=$2|" "$ENV_FILE" > "$ENV_FILE.new" && mv "$ENV_FILE.new" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}
if [ ! -f "$ENV_FILE" ]; then
  cp "$ETC_DIR/famhomebase.env.example" "$ENV_FILE"
  # An install made before 0.3.0 kept its settings in ~/famhomebase/.env. Take over what still means something (not the port, the
  # folder or the browser profile: those moved).
  user_home=$(getent passwd "${USER_NAME:-root}" 2>/dev/null | cut -d: -f6)
  old="${FAMHOMEBASE_LEGACY_ENV:-${user_home:-/root}/famhomebase/.env}"
  if [ -f "$old" ]; then
    for key in FAMHOMEBASE_ENV FAMHOMEBASE_API_URL AUTO_UPDATE CHECK_INTERVAL_HOURS FAMHOMEBASE_IMAGE; do
      val=$(sed -n "s/^$key=\\(.*\\)\$/\\1/p" "$old" | tail -n 1 | tr -d '\r')
      [ -n "$val" ] && set_env "$key" "$val"
    done
    say "Took over your settings from $old. That folder is not used any more: once the display works you can delete it."
  fi
fi
if [ -n "$ENVNAME" ]; then set_env FAMHOMEBASE_ENV "$ENVNAME"; fi
if [ -n "$API_URL" ]; then
  set_env FAMHOMEBASE_API_URL "$API_URL"
elif [ "$ENVNAME" = staging ]; then
  set_env FAMHOMEBASE_API_URL https://staging.famhomebase.mc-esolutions.ca
elif [ "$ENVNAME" = prod ]; then
  set_env FAMHOMEBASE_API_URL https://famhomebase.mc-esolutions.ca
fi
if [ -n "$PORT" ]; then set_env FAMHOMEBASE_PORT "$PORT"; fi
grep -q '^FAMHOMEBASE_PORT=' "$ENV_FILE" || set_env FAMHOMEBASE_PORT 80
PORT=$(sed -n 's/^FAMHOMEBASE_PORT=\([0-9][0-9]*\)$/\1/p' "$ENV_FILE" | tail -n 1)

# the image the version names (pulled here so a missing or private package is said plainly, before anything is started)
image=$(sed -n 's/^FAMHOMEBASE_IMAGE=\(.*\)$/\1/p' "$ENV_FILE" | tail -n 1)
image=${image:-ghcr.io/mcesolutionsinc/famhomebase-pi}
if [ "$START" -eq 1 ]; then
  say "Downloading the display image (the first time takes a minute)..."
  docker pull "$image:$WANT" >/dev/null 2>&1 || die "could not pull $image:$WANT. If it says denied, the package is not public yet; if the Docker daemon is not reachable, is it running (systemctl status docker)?"
fi

host_args=""
[ -n "$USER_NAME" ] && host_args="--user $USER_NAME"
[ "$KIOSK" -eq 1 ] && host_args="$host_args --kiosk"
[ "$START" -eq 0 ] && host_args="$host_args --no-start"
# shellcheck disable=SC2086 # a short list of flags
sh "$LIB_DIR/host-setup.sh" $host_args

if [ "$PORT" = 80 ]; then LOCAL_URL="http://localhost"; else LOCAL_URL="http://localhost:$PORT"; fi
say ""
say "Done. FamHomeBase display $WANT is installed (the command: famhomebase status)."
say "  The display shows a QR code and a code. Scan it with a phone (or open <the site>/app/pair and type the code), sign in, name the device"
say "  and pick a display."
say "  The Pi's own screen:  $LOCAL_URL/?kiosk=1   (with --kiosk it opens by itself at boot). Only this machine can reach it."
say "  Settings: $ENV_FILE. It looks for new releases by itself every few hours; see $DOC_DIR/INSTALL.md to turn that off."
