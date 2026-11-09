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
if "$DOCKER" load -i "$FILE" >/dev/null 2>&1; then
  jlog info "loaded"
else
  jlog warn "could not load $FILE: the display image will be downloaded instead"
fi
rm -f "$FILE"
exit 0
