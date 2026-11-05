#!/bin/sh
# Keeps the kiosk line in a labwc autostart file (~/.config/labwc/autostart) current. Used by install.sh and by the updater.
#
#   fix-autostart.sh AUTOSTART_FILE LOCAL_URL [--add]
#
# If the file already has a line that opens the dashboard (one containing "kiosk=1" — this script's own, or a hand-made copy)
# that line is replaced with the current one (right address, current flags); every other line is left alone. With --add, a file
# without such a line gets one appended (and a missing file is created). The old file is saved as AUTOSTART_FILE.bak.
# Prints one word: changed, added, unchanged or absent (no kiosk line, and --add not given).
set -eu

file=${1:?usage: fix-autostart.sh AUTOSTART_FILE LOCAL_URL [--add]}
url=${2:?usage: fix-autostart.sh AUTOSTART_FILE LOCAL_URL [--add]}
add=${3:-}

comment="# Wait for the dashboard to be up, then open it full-screen on the Pi's display."
line=$(cat <<'KIOSK_EOF'
sh -c 'until curl -sf __URL__/ >/dev/null; do sleep 2; done; B=$(command -v chromium || command -v chromium-browser); exec "$B" --ozone-platform=wayland --kiosk --noerrdialogs --disable-infobars --no-first-run --password-store=basic "__URL__/?kiosk=1"' &
KIOSK_EOF
)
line=$(printf '%s' "$line" | sed "s|__URL__|$url|g")

backup() {
  cp -f "$file" "$file.bak"
  # run as root by the updater: give the copy the file's owner, not root's
  owner=$(stat -c '%u:%g' "$file" 2>/dev/null) && chown "$owner" "$file.bak" 2>/dev/null || true
}

if [ -f "$file" ] && grep -q 'kiosk=1' "$file"; then
  new=$(mktemp)
  awk -v line="$line" '/kiosk=1/ { if (!done) { print line; done = 1 } ; next } { print }' "$file" > "$new"
  if cmp -s "$file" "$new"; then
    rm -f "$new"
    echo unchanged
    exit 0
  fi
  backup
  cat "$new" > "$file" # written in place, so the file keeps its owner and mode
  rm -f "$new"
  echo changed
elif [ "$add" = "--add" ]; then
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] && backup
  new=$(mktemp)
  { [ -f "$file" ] && cat "$file"; printf '%s\n%s\n' "$comment" "$line"; } > "$new"
  cat "$new" > "$file"
  rm -f "$new"
  echo added
else
  echo absent
fi
