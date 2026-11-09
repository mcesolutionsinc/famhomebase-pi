#!/bin/sh
# Opens the dashboard full-screen. It is the one program `cage` (a compositor that shows a single app and nothing else: no desktop, no
# panel) runs, started by the famhomebase-kiosk systemd service as its own service user (see host-setup.sh). The unit just points at
# cage and cage at this script, and everything that can change lives here and in the settings file, so an update replaces this file
# and the display follows.
#
# Screen rotation is not done here: it is a setting of the device on the website and the app turns itself.
#
# Reads from /etc/famhomebase/famhomebase.env:
#   FAMHOMEBASE_PORT     the port the dashboard is on (default 80)
#   FAMHOMEBASE_PROFILE  the folder Chromium keeps its saved data in (default /var/lib/famhomebase/kiosk-profile). The display keeps
#                        its pairing credential and its last layout there, so a restart or a power cut leaves it paired.
set -u

ENV_FILE="${FAMHOMEBASE_ETC_DIR:-/etc/famhomebase}/famhomebase.env"
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$ENV_FILE" 2>/dev/null | tail -n 1; }

PORT=$(getenv FAMHOMEBASE_PORT)
case "$PORT" in ''|*[!0-9]*) PORT=80 ;; esac
[ -z "$(getenv FAMHOMEBASE_ROTATE)" ] || echo "kiosk: FAMHOMEBASE_ROTATE is ignored since 0.4.0: set the rotation on the website (Devices, the device's Settings)" >&2
PROFILE=$(getenv FAMHOMEBASE_PROFILE)
[ -n "$PROFILE" ] || PROFILE="${FAMHOMEBASE_STATE_DIR:-/var/lib/famhomebase}/kiosk-profile"
case "$PROFILE" in
  /*) ;;
  *) echo "kiosk: FAMHOMEBASE_PROFILE must be a full path starting with / (got '$PROFILE')" >&2; exit 1 ;;
esac
if [ "$PORT" = 80 ]; then URL=http://localhost; else URL="http://localhost:$PORT"; fi

# The bridge: the boot splash has ended and the browser needs several seconds to start, which would be a black screen. Show the logo picture
# (assets/bridge/frame-R.png: a whole dark screen with the logo as the splash drew it, already turned for how the screen is mounted) in a
# window of its own at once. The browser's window opens on top of it later and cage shows the newest window, so nothing has to close it.
# Without the picture or the viewer (swayimg) the screen is simply black a little longer. (The viewer's own errors go to the journal.)
HERE=$(dirname "$0")
STATE="${FAMHOMEBASE_STATE_DIR:-/var/lib/famhomebase}"
ROT=$(cat "$STATE/state/rotation" 2>/dev/null)
case "$ROT" in 0|90|180|270) ;; *) ROT=0 ;; esac
FRAME="$HERE/bridge/frame-$ROT.png"
VIEWER=${FAMHOMEBASE_SWAYIMG:-swayimg}
if [ -f "$FRAME" ] && command -v "$VIEWER" >/dev/null 2>&1; then
  "$VIEWER" --fullscreen --scale=fit -c viewer.window='#0A1327' -c info.show=no "$FRAME" >/dev/null &
else
  echo '{"level":"info","component":"kiosk","msg":"no bridge picture shown (no picture or no swayimg)"}' >&2
fi

# The browser can start before Docker has the dashboard up; wait for it.
until curl -sf "$URL/" >/dev/null; do sleep 2; done

BROWSER=$(command -v chromium || command -v chromium-browser) || { echo "kiosk: chromium is not installed" >&2; exit 1; }
mkdir -p "$PROFILE" || { echo "kiosk: cannot make the profile folder $PROFILE" >&2; exit 1; }
# After a power cut Chromium leaves its lock files behind; if the process id in one has since been given to something else it
# refuses to start on a screen nobody can click. This script is the only thing that opens this profile, so the locks are stale.
rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie"
# Chromium downloads a DRM component (Widevine) into its profile the first time it runs. On a Pi the next start then dies at once
# ("Zygote process exited prematurely") and the screen stays black until the profile is cleaned. A wall display plays no protected media:
# no component downloads (--disable-component-update) and any Widevine folder already in the profile is dropped (found on the first real Pi).
rm -rf "$PROFILE/WidevineCdm"
# --user-data-dir: a saved profile of its own, apart from anyone's everyday Chromium. --hide-crash-restore-bubble: after a power cut
# Chromium would otherwise ask "Restore pages?" on a screen nobody can click.
exec "$BROWSER" --ozone-platform=wayland --kiosk --noerrdialogs --disable-infobars --no-first-run --disable-component-update --password-store=basic --user-data-dir="$PROFILE" --hide-crash-restore-bubble "$URL/?kiosk=1"
