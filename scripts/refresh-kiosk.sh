#!/bin/sh
# Restart the Pi's full-screen browser (e.g. after you change something from your laptop). Run it over SSH.
HERE=$(cd "$(dirname "$0")" && pwd)
PORT=$(sed -n 's/^FAMHOMEBASE_PORT=\([0-9][0-9]*\)$/\1/p' "$HERE/../.env" 2>/dev/null | tail -n 1)
PORT=${PORT:-80}
pkill chromium
sleep 2
XDG_RUNTIME_DIR=/run/user/$(id -u)
WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR WAYLAND_DISPLAY
nohup chromium --ozone-platform=wayland --kiosk --noerrdialogs --disable-infobars --no-first-run --password-store=basic "http://localhost:$PORT/?kiosk=1" >/dev/null 2>&1 &
