#!/bin/sh
# Opens the dashboard full-screen on this Pi's display. Run by the famhomebase-kiosk systemd user unit (see scripts/install.sh)
# — the unit just points at this script, and everything that can change lives here and in .env, so an update replaces this file
# and the display follows with nothing in your home folder to correct.
#
# Reads from .env (next to this folder):
#   FAMHOMEBASE_PORT     the port the dashboard is on (default 80)
#   FAMHOMEBASE_ROTATE   rotate the screen: 90, 180 or 270 (or normal). Unset = leave the screen alone.
#   FAMHOMEBASE_OUTPUT   which display to rotate, e.g. HDMI-A-1. Unset = the first one `wlr-randr` lists.
#   FAMHOMEBASE_PROFILE  the folder Chromium keeps its saved data in (default ~/.local/share/famhomebase-kiosk). The cloud display keeps
#                        its pairing credential and its last layout there, so a restart or a power cut leaves it paired.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$HERE/../.env"
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$ENV_FILE" 2>/dev/null | tail -n 1; }

PORT=$(getenv FAMHOMEBASE_PORT)
case "$PORT" in ''|*[!0-9]*) PORT=80 ;; esac
ROTATE=$(getenv FAMHOMEBASE_ROTATE)
OUTPUT=$(getenv FAMHOMEBASE_OUTPUT)
PROFILE=$(getenv FAMHOMEBASE_PROFILE)
[ -n "$PROFILE" ] || PROFILE="${HOME:-/tmp}/.local/share/famhomebase-kiosk"
if [ "$PORT" = 80 ]; then URL=http://localhost; else URL="http://localhost:$PORT"; fi

XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR WAYLAND_DISPLAY

# The unit starts when the user's session does, which can be before the desktop is up: wait for it (about 5 minutes, then
# exit so systemd tries again).
waited=0
until [ -e "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; do
  waited=$((waited + 1))
  [ "$waited" -gt 150 ] && { echo "kiosk: no desktop session found at $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" >&2; exit 1; }
  sleep 2
done

# Screen rotation, if asked for.
case "$ROTATE" in
  '') ;;
  normal|90|180|270)
    if command -v wlr-randr >/dev/null 2>&1; then
      out=$OUTPUT
      [ -n "$out" ] || out=$(wlr-randr | awk '/^[^ ]/ { print $1; exit }')
      if [ -n "$out" ]; then
        wlr-randr --output "$out" --transform "$ROTATE" || echo "kiosk: could not rotate $out" >&2
      else
        echo "kiosk: FAMHOMEBASE_ROTATE is set but no display was found to rotate" >&2
      fi
    else
      echo "kiosk: FAMHOMEBASE_ROTATE is set but wlr-randr is not installed (sudo apt install wlr-randr)" >&2
    fi ;;
  *) echo "kiosk: ignoring FAMHOMEBASE_ROTATE='$ROTATE' (use 90, 180, 270 or normal)" >&2 ;;
esac

# The browser can start before Docker has the dashboard up; wait for it.
until curl -sf "$URL/" >/dev/null; do sleep 2; done

BROWSER=$(command -v chromium || command -v chromium-browser) || { echo "kiosk: chromium is not installed" >&2; exit 1; }
mkdir -p "$PROFILE" || { echo "kiosk: cannot make the profile folder $PROFILE" >&2; exit 1; }
# --user-data-dir: a saved profile of its own, apart from anyone's everyday Chromium. --hide-crash-restore-bubble: after a power cut
# Chromium would otherwise ask "Restore pages?" on a screen nobody can click.
exec "$BROWSER" --ozone-platform=wayland --kiosk --noerrdialogs --disable-infobars --no-first-run --password-store=basic --user-data-dir="$PROFILE" --hide-crash-restore-bubble "$URL/?kiosk=1"
