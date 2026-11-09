#!/bin/sh
# FamHomeBase display for Raspberry Pi (or any 64-bit Linux with Docker and systemd): installer. Also the re-installer: running it
# again on an existing install brings it up to date and keeps your .env.
#
#   curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/download/vX.Y.Z/install.sh | sh -s -- --kiosk
#
# Options:
#   --dir DIR        where to install (default: ~/famhomebase)
#   --version X.Y.Z  install that release instead of the newest release
#   --env NAME       prod (default) or staging; staging shows a STAGING banner and points at the staging site
#   --api-url URL    where the cloud is, https://host with no path (default: the site that goes with --env)
#   --port N         the port to browse to (default 80; it must be free, 8080 is a common alternative)
#   --kiosk          also show the display full-screen at boot (Raspberry Pi OS desktop): turns on desktop autologin and runs the
#                    kiosk as a systemd user service
#   --no-start       set everything up, but don't start anything
#
# Needs Docker already installed (docs/INSTALL.md) and sudo. Compose is not needed: the display is one container started by systemd.
set -eu

REPO="${FAMHOMEBASE_REPO:-mcesolutionsinc/famhomebase-pi}"
API="${GITHUB_API:-https://api.github.com}"
DL="${GITHUB_DOWNLOAD:-https://github.com}"
DIR="${FAMHOMEBASE_DIR:-$HOME/famhomebase}"
CURL="${CURL:-curl}"
WANT=""; ENVNAME=""; API_URL=""; PORT=""; KIOSK=0; START=1

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die "--dir needs a folder"; DIR=$2; shift ;;
    --version) [ $# -ge 2 ] || die "--version needs a number like 0.1.0"; WANT=${2#v}; shift ;;
    --env) [ $# -ge 2 ] || die "--env needs prod or staging"; ENVNAME=$2; shift ;;
    --api-url) [ $# -ge 2 ] || die "--api-url needs an address like https://famhomebase.mc-esolutions.ca"; API_URL=$2; shift ;;
    --port) [ $# -ge 2 ] && [ -n "$2" ] || die "--port needs a number"; PORT=$2; shift ;;
    --kiosk) KIOSK=1 ;;
    --no-start) START=0 ;;
    -h|--help) sed -n '2,17p' "$0" 2>/dev/null || true; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed. $2"; }
need curl "Install it with: sudo apt install curl"
need tar "Install it with: sudo apt install tar"
need sha256sum "Install it with: sudo apt install coreutils"
need systemctl "This installer needs systemd."
[ "$(id -u)" -eq 0 ] || need sudo "Install it with: apt install sudo (or run the installer as root)"
need docker "Install Docker first: see https://github.com/$REPO/blob/main/docs/INSTALL.md (section 'Install Docker')"

# the folder goes into unit files and .env: keep to a plain path
echo "$DIR" | grep -Eq '^[A-Za-z0-9._/~-]+$' || die "the install folder '$DIR' has spaces or special characters: use a plain path such as ~/famhomebase"
case "$ENVNAME" in ''|prod|staging) ;; *) die "'$ENVNAME' is not an environment: use prod or staging" ;; esac
if [ -n "$API_URL" ]; then
  echo "$API_URL" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?$' || die "'$API_URL' is not an address like https://famhomebase.mc-esolutions.ca (https, a host, no path)"
fi
if [ -n "$PORT" ]; then
  echo "$PORT" | grep -Eq '^[0-9]+$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "'$PORT' is not a port number (1-65535)"
fi

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

existing=""
[ -f "$DIR/VERSION" ] && existing=$(tr -d ' \r\n' < "$DIR/VERSION")
mkdir -p "$DIR"
# unpacked aside and copied in: an archive's entry for its own folder ("./") must not change the mode or owner of the install folder
mkdir "$tmp/new" && tar --no-same-owner -xzf "$tmp/$name.tar.gz" -C "$tmp/new" && cp -R "$tmp/new/." "$DIR/" || die "could not unpack release $WANT"
DIR=$(cd "$DIR" && pwd)
if [ -n "$existing" ]; then say "Updated $existing -> $WANT in $DIR"; else say "Installed in $DIR"; fi

# .env: created once and then only the settings you passed are changed, so your other choices survive a re-run.
set_env() { # key, value
  if grep -q "^$1=" "$DIR/.env"; then
    sed "s|^$1=.*|$1=$2|" "$DIR/.env" > "$DIR/.env.new" && mv "$DIR/.env.new" "$DIR/.env"
  else
    printf '%s=%s\n' "$1" "$2" >> "$DIR/.env"
  fi
}
[ -f "$DIR/.env" ] || cp "$DIR/.env.example" "$DIR/.env"
set_env FAMHOMEBASE_DIR "$DIR"
if [ -n "$ENVNAME" ]; then set_env FAMHOMEBASE_ENV "$ENVNAME"; fi
if [ -n "$API_URL" ]; then
  set_env FAMHOMEBASE_API_URL "$API_URL"
elif [ "$ENVNAME" = staging ]; then
  set_env FAMHOMEBASE_API_URL https://staging.famhomebase.mc-esolutions.ca
elif [ "$ENVNAME" = prod ]; then
  set_env FAMHOMEBASE_API_URL https://famhomebase.mc-esolutions.ca
fi
if [ -n "$PORT" ]; then set_env FAMHOMEBASE_PORT "$PORT"; fi
grep -q '^FAMHOMEBASE_PORT=' "$DIR/.env" || set_env FAMHOMEBASE_PORT 80
PORT=$(sed -n 's/^FAMHOMEBASE_PORT=\([0-9][0-9]*\)$/\1/p' "$DIR/.env" | tail -n 1)

# the image the version names (pulled here so a missing or private package is said plainly, before anything is started)
image=$(sed -n 's/^FAMHOMEBASE_IMAGE=\(.*\)$/\1/p' "$DIR/.env" | tail -n 1)
image=${image:-ghcr.io/mcesolutionsinc/famhomebase-pi}
if [ "$START" -eq 1 ]; then
  say "Downloading the display image (the first time takes a minute)..."
  docker pull "$image:$WANT" >/dev/null 2>&1 || sudo docker pull "$image:$WANT" || die "could not pull $image:$WANT. If it says denied, the package is not public yet; if the Docker daemon is not reachable, add yourself to the docker group (sudo usermod -aG docker \$USER), log out and back in, and run this again."
fi

host_args="--user $(id -un)"
[ "$KIOSK" -eq 1 ] && host_args="$host_args --kiosk"
[ "$START" -eq 0 ] && host_args="$host_args --no-start"
# shellcheck disable=SC2086 # a short list of flags
sh "$DIR/scripts/host-setup.sh" $host_args

if [ "$PORT" = 80 ]; then LOCAL_URL="http://localhost"; else LOCAL_URL="http://localhost:$PORT"; fi
say ""
say "Done. FamHomeBase display $WANT is installed in $DIR."
say "  The display shows a QR code and a code. Scan it with a phone (or open <the site>/app/pair and type the code), sign in, name the device"
say "  and pick a display."
say "  The Pi's own screen:  $LOCAL_URL/?kiosk=1   (with --kiosk it opens by itself at boot)"
say "  It looks for new releases by itself every few hours; see docs/INSTALL.md to turn that off."
