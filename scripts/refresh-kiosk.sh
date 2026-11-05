#!/bin/sh
# Restart the Pi's full-screen browser (after you change something from your laptop, or edit .env). Run it over SSH.
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export XDG_RUNTIME_DIR
if systemctl --user cat famhomebase-kiosk.service >/dev/null 2>&1; then
  exec systemctl --user restart famhomebase-kiosk.service
fi
echo "The kiosk service isn't installed. Run the installer with --kiosk (see docs/INSTALL.md)." >&2
exit 1
