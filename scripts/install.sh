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
#   --kiosk          also make this Pi show the dashboard full-screen at boot (Raspberry Pi OS desktop, labwc): installs a
#                    systemd user service that runs scripts/kiosk.sh. (An older install that opened the dashboard from
#                    ~/.config/labwc/autostart is moved over to the service automatically.)
#   --rotate DEG     rotate the Pi's screen: 90, 180, 270 or normal (saved as FAMHOMEBASE_ROTATE in .env)
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
ROTATE=""
START=1
KIOSK=0

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die "--dir needs a folder"; DIR=$2; shift ;;
    --version) [ $# -ge 2 ] || die "--version needs a number like 0.1.5"; WANT=${2#v}; shift ;;
    --port) [ $# -ge 2 ] && [ -n "$2" ] || die "--port needs a number"; PORT=$2; shift ;;
    --rotate) [ $# -ge 2 ] && [ -n "$2" ] || die "--rotate needs 90, 180, 270 or normal"; ROTATE=$2; shift ;;
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
case "$ROTATE" in ''|normal|90|180|270) ;; *) die "'$ROTATE' is not a rotation: use 90, 180, 270 or normal" ;; esac
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

# The port: --port wins; else what .env already says (so re-running keeps your choice); else 80, the default.
if [ -n "$PORT" ]; then
  if grep -q '^FAMHOMEBASE_PORT=' "$DIR/.env"; then
    sed "s|^FAMHOMEBASE_PORT=.*|FAMHOMEBASE_PORT=$PORT|" "$DIR/.env" > "$DIR/.env.new" && mv "$DIR/.env.new" "$DIR/.env"
  else
    printf 'FAMHOMEBASE_PORT=%s\n' "$PORT" >> "$DIR/.env"
  fi
else
  PORT=$(sed -n 's/^FAMHOMEBASE_PORT=\([0-9][0-9]*\)$/\1/p' "$DIR/.env" | tail -n 1)
  if [ -z "$PORT" ]; then
    PORT=80
    printf 'FAMHOMEBASE_PORT=80\n' >> "$DIR/.env"
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

# Rotation is a setting in .env that scripts/kiosk.sh applies when the display starts.
if [ -n "$ROTATE" ]; then
  if grep -q '^FAMHOMEBASE_ROTATE=' "$DIR/.env"; then
    sed "s|^FAMHOMEBASE_ROTATE=.*|FAMHOMEBASE_ROTATE=$ROTATE|" "$DIR/.env" > "$DIR/.env.new" && mv "$DIR/.env.new" "$DIR/.env"
  else
    printf 'FAMHOMEBASE_ROTATE=%s\n' "$ROTATE" >> "$DIR/.env"
  fi
fi

# The kiosk display (Raspberry Pi OS desktop, labwc): a systemd user service that runs scripts/kiosk.sh. The script reads the
# port and rotation from .env and an update replaces it, so nothing here needs correcting again. An older install opened the
# dashboard from a line in ~/.config/labwc/autostart; if that line is there, this Pi is a kiosk, so move it over to the service.
autostart="$HOME/.config/labwc/autostart"
legacy=0
{ [ -f "$autostart" ] && grep -q 'kiosk=1' "$autostart"; } && legacy=1

if [ "$KIOSK" -eq 1 ] || [ "$legacy" -eq 1 ]; then
  if [ "$KIOSK" -eq 1 ]; then
    say "Setting this Pi to show the dashboard full-screen at boot..."
    if command -v raspi-config >/dev/null 2>&1; then
      sudo raspi-config nonint do_boot_behaviour B4 || say "  (could not turn on desktop autologin — do it in raspi-config: System Options > Boot / Auto Login)"
    else
      say "  (raspi-config not found — make sure this machine logs into its desktop automatically)"
    fi
    # The display tools the kiosk uses: wlr-randr rotates the screen, wlopm turns it off at night (Settings → Night mode).
    missing=""
    for tool in wlr-randr wlopm; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done
    if [ -n "$missing" ]; then
      say "Installing the screen tools:$missing"
      # shellcheck disable=SC2086 # a list of package names
      sudo apt-get install -y $missing >/dev/null 2>&1 || say "  (could not install them — run: sudo apt install$missing)"
    fi
  fi

  unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"
  cat > "$unit_dir/famhomebase-kiosk.service" <<UNIT_EOF
[Unit]
Description=FamHomeBase kiosk display

[Service]
ExecStart=$DIR/scripts/kiosk.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT_EOF

  if [ "$legacy" -eq 1 ]; then
    cp -f "$autostart" "$autostart.bak"
    awk '/kiosk=1/ || /^# Wait for the dashboard to be up, then open it full-screen/ { next } { print }' "$autostart.bak" > "$autostart.new" && cat "$autostart.new" > "$autostart"
    rm -f "$autostart.new"
    say "Moved the kiosk from $autostart to a systemd service (the old file is saved as autostart.bak; your other lines in it stay)."
    pkill -x chromium >/dev/null 2>&1 || true # the old kiosk's browser: the service starts its own
  fi

  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  export XDG_RUNTIME_DIR
  if systemctl --user daemon-reload >/dev/null 2>&1; then
    if [ "$START" -eq 1 ]; then systemctl --user enable --now famhomebase-kiosk.service >/dev/null 2>&1 && say "  The kiosk service is running; restart it any time with: systemctl --user restart famhomebase-kiosk"
    else systemctl --user enable famhomebase-kiosk.service >/dev/null 2>&1; fi
  else
    say "  Could not reach your user's systemd (normal when run from a session with no desktop login yet). It starts at the next login; or run: systemctl --user enable --now famhomebase-kiosk.service"
  fi
elif [ -n "$ROTATE" ] && systemctl --user is-active famhomebase-kiosk.service >/dev/null 2>&1; then
  systemctl --user restart famhomebase-kiosk.service >/dev/null 2>&1 || true
fi

say ""
say "Done. FamHomeBase $WANT is installed in $DIR."
say "  Set it up from a laptop on the same network:  $BASE_URL/   (find the address with: hostname -I)"
say "  The Pi's own screen:                            $LOCAL_URL/?kiosk=1"
say "  It checks for new releases by itself; see docs/INSTALL.md to turn that off."
