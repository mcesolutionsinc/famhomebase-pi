#!/bin/sh
# FamHomeBase for Raspberry Pi — installer. Also the upgrader: running it again on an existing install brings it up to date
# without touching your ./data, ./secrets or .env.
#
#   curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sh
#   curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sh -s -- --kiosk
#
# Options:
#   --dir DIR        where to install (default: ~/famhomebase-pi)
#   --version X.Y.Z  install that release instead of the latest
#   --port N         the port to browse to (default 80, giving http://<address>/ — it must be free; 8080 is a common alternative)
#   --kiosk          also make this Pi show the dashboard full-screen at boot (Raspberry Pi OS desktop)
#   --no-start       download and set up, but don't start the containers
#
# Needs Docker with the Compose plugin already installed (see docs/INSTALL.md).
set -eu

REPO="${FAMHOMEBASE_REPO:-mcesolutionsinc/famhomebase-pi}"
API="${GITHUB_API:-https://api.github.com}"
DL="${GITHUB_DOWNLOAD:-https://github.com}"
DIR="${FAMHOMEBASE_DIR:-$HOME/famhomebase-pi}"
WANT=""
PORT=""
START=1
KIOSK=0

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die "--dir needs a folder"; DIR=$2; shift ;;
    --version) [ $# -ge 2 ] || die "--version needs a number like 0.1.5"; WANT=${2#v}; shift ;;
    --port) [ $# -ge 2 ] && [ -n "$2" ] || die "--port needs a number"; PORT=$2; shift ;;
    --kiosk) KIOSK=1 ;;
    --no-start) START=0 ;;
    -h|--help) sed -n '2,15p' "$0" 2>/dev/null || true; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed. $2"; }
need curl "Install it with: sudo apt install curl"
need tar "Install it with: sudo apt install tar"
need sha256sum "Install it with: sudo apt install coreutils"
need docker "Install Docker first — see https://github.com/$REPO/blob/main/docs/INSTALL.md (section 'Install Docker')"
docker compose version >/dev/null 2>&1 || die "the Docker Compose plugin is missing (\`docker compose version\` fails). See the install guide's 'Install Docker' section."

if [ -z "$WANT" ]; then
  say "Looking up the latest release..."
  tag=$(curl -fsSL "$API/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1) || true
  [ -n "${tag:-}" ] || die "could not find the latest release of $REPO (offline, or none published yet)"
  WANT=${tag#v}
fi
if [ -n "$PORT" ]; then
  echo "$PORT" | grep -Eq '^[0-9]+$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "'$PORT' is not a port number (1-65535)"
fi
echo "$WANT" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "'$WANT' is not a version like 0.1.5"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
name="famhomebase-pi-$WANT"
say "Downloading FamHomeBase $WANT..."
curl -fsSL -o "$tmp/$name.tar.gz" "$DL/$REPO/releases/download/v$WANT/$name.tar.gz" || die "could not download release $WANT"
curl -fsSL -o "$tmp/$name.tar.gz.sha256" "$DL/$REPO/releases/download/v$WANT/$name.tar.gz.sha256" || die "could not download its checksum"
expected=$(cut -d' ' -f1 < "$tmp/$name.tar.gz.sha256")
actual=$(sha256sum "$tmp/$name.tar.gz" | cut -d' ' -f1)
[ -n "$expected" ] && [ "$expected" = "$actual" ] || die "checksum mismatch — the download is damaged or not what was published. Nothing was installed."

existing=""
[ -f "$DIR/VERSION" ] && existing=$(tr -d ' \r\n' < "$DIR/VERSION")
had_env=1
[ -f "$DIR/.env" ] || had_env=0
mkdir -p "$DIR"
tar -xzf "$tmp/$name.tar.gz" -C "$DIR"
DIR=$(cd "$DIR" && pwd)
if [ -n "$existing" ] && [ "$existing" != dev ]; then say "Updated $existing -> $WANT in $DIR"; else say "Installed in $DIR"; fi

# .env: created once, never overwritten (it may hold the owner's choices); only FAMHOMEBASE_DIR is kept correct.
if [ ! -f "$DIR/.env" ]; then
  sed "s|^FAMHOMEBASE_DIR=.*|FAMHOMEBASE_DIR=$DIR|" "$DIR/.env.example" > "$DIR/.env"
elif ! grep -q '^FAMHOMEBASE_DIR=' "$DIR/.env"; then
  printf 'FAMHOMEBASE_DIR=%s\n' "$DIR" >> "$DIR/.env"
fi

# The port: --port wins; else what .env already says (so re-running keeps your choice); else 80 for a new install. An install
# from before 80 became the default has been on 8080 and has no setting yet — keep it there rather than move it unasked.
if [ -n "$PORT" ]; then
  if grep -q '^FAMHOMEBASE_PORT=' "$DIR/.env"; then
    sed "s|^FAMHOMEBASE_PORT=.*|FAMHOMEBASE_PORT=$PORT|" "$DIR/.env" > "$DIR/.env.new" && mv "$DIR/.env.new" "$DIR/.env"
  else
    printf 'FAMHOMEBASE_PORT=%s\n' "$PORT" >> "$DIR/.env"
  fi
else
  PORT=$(sed -n 's/^FAMHOMEBASE_PORT=\([0-9][0-9]*\)$/\1/p' "$DIR/.env" | tail -n 1)
  if [ -z "$PORT" ]; then
    if [ "$had_env" -eq 1 ]; then
      PORT=8080
      say "Keeping this install on port 8080, which it has been using (change it any time with --port)."
    else
      PORT=80
    fi
    printf 'FAMHOMEBASE_PORT=%s\n' "$PORT" >> "$DIR/.env"
  fi
fi
if [ "$PORT" = 80 ]; then BASE_URL="http://<this-machine's address>"; LOCAL_URL="http://localhost"; else BASE_URL="http://<this-machine's address>:$PORT"; LOCAL_URL="http://localhost:$PORT"; fi

if [ ! -f "$DIR/secrets/dashboard.key" ]; then
  say "Creating the encryption key..."
  (cd "$DIR" && sh ./scripts/generate-key.sh)
  say "  Back up $DIR/secrets/dashboard.key somewhere other than this disk."
fi

if [ "$START" -eq 1 ]; then
  say "Starting FamHomeBase (the first start downloads the images)..."
  (cd "$DIR" && docker compose pull && docker compose up -d) || die "docker compose failed. If it says permission denied, add yourself to the docker group (sudo usermod -aG docker \$USER), log out and back in, and run this again. If it says the port is already in use, run this again with --port 8080 (or any free port)."
fi

# The kiosk autostart (Raspberry Pi OS desktop, labwc). The line that opens the dashboard is kept current on every run: if an
# autostart file already has one (this installer's, or a hand-made copy of it), it is corrected in place — right port, current
# flags — and any other lines in the file are left alone. --kiosk additionally adds the line when there is none, and turns on
# desktop autologin.
autostart="$HOME/.config/labwc/autostart"
kiosk_comment="# Wait for the dashboard to be up, then open it full-screen on the Pi's display."
kiosk_line=$(cat <<'KIOSK_EOF'
sh -c 'until curl -sf __URL__/ >/dev/null; do sleep 2; done; B=$(command -v chromium || command -v chromium-browser); exec "$B" --ozone-platform=wayland --kiosk --noerrdialogs --disable-infobars --no-first-run --password-store=basic "__URL__/?kiosk=1"' &
KIOSK_EOF
)
kiosk_line=$(printf '%s' "$kiosk_line" | sed "s|__URL__|$LOCAL_URL|g")

if [ "$KIOSK" -eq 1 ]; then
  say "Setting this Pi to show the dashboard full-screen at boot..."
  if command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4 || say "  (could not turn on desktop autologin — do it in raspi-config: System Options > Boot / Auto Login)"
  else
    say "  (raspi-config not found — make sure this machine logs into its desktop automatically)"
  fi
fi

if [ -f "$autostart" ] && grep -q 'kiosk=1' "$autostart"; then
  awk -v line="$kiosk_line" '/kiosk=1/ { if (!done) { print line; done = 1 } ; next } { print }' "$autostart" > "$autostart.new"
  if cmp -s "$autostart" "$autostart.new"; then
    rm -f "$autostart.new"
  else
    cp -f "$autostart" "$autostart.bak"
    mv "$autostart.new" "$autostart"
    say "Corrected the kiosk line in $autostart (it opens $LOCAL_URL/?kiosk=1 now; the old file is saved as autostart.bak)."
    say "  Run ~/famhomebase-pi/scripts/refresh-kiosk.sh, or reboot, to restart the display with it."
  fi
elif [ "$KIOSK" -eq 1 ]; then
  mkdir -p "$(dirname "$autostart")"
  [ -f "$autostart" ] && cp -f "$autostart" "$autostart.bak"
  { [ -f "$autostart" ] && cat "$autostart"; printf '%s\n%s\n' "$kiosk_comment" "$kiosk_line"; } > "$autostart.new"
  mv "$autostart.new" "$autostart"
  say "  Wrote $autostart (an existing one is kept, with the kiosk line added, and saved as autostart.bak). Reboot to start the display."
fi

say ""
say "Done. FamHomeBase $WANT is installed in $DIR."
say "  Set it up from a laptop on the same network:  $BASE_URL/   (find the address with: hostname -I)"
say "  The Pi's own screen:                            $LOCAL_URL/?kiosk=1"
say "  It checks for new releases by itself; see docs/INSTALL.md to turn that off."
