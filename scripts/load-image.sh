#!/bin/sh
# First boot of a ready-made system image: loads the display's Docker image that was saved inside the image file
# (/var/lib/famhomebase/image.tar.gz, put there by tools/build-image.sh), so the display starts at once and needs no download. It runs once:
# the file is deleted after the first try, whether it loaded or not. If it did not load, the display is simply downloaded as on any install
# (so a damaged file costs a download, never a stuck display). Started by famhomebase-image-load.service (host-setup.sh), only when the
# file exists, and before the display's own service.
set -u

jlog() { printf '{"ts":"%s","level":"%s","component":"load-image","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }

STATE="${FAMHOMEBASE_STATE_DIR:-/var/lib/famhomebase}"
DOCKER=${DOCKER:-docker}
FILE="$STATE/image.tar.gz"

[ -f "$FILE" ] || exit 0
jlog info "loading the display image that came with this system image"
# the daemon can be a moment from ready on a first boot: three tries, a few seconds apart, before giving up
SLEEP=${FAMHOMEBASE_LOAD_RETRY_SLEEP:-3}
loaded=0; try=1
while [ "$try" -le 3 ]; do
  if "$DOCKER" load -i "$FILE" >/dev/null 2>&1; then loaded=1; break; fi
  jlog warn "could not load $FILE (try $try of 3)"
  [ "$try" -lt 3 ] && sleep "$SLEEP"
  try=$((try+1))
done
if [ "$loaded" -eq 1 ]; then jlog info "loaded"; else jlog warn "could not load $FILE: the display image will be downloaded instead"; fi
rm -f "$FILE"
exit 0
