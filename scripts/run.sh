#!/bin/sh
# Runs the FamHomeBase display container. This is what the famhomebase systemd unit starts (see host-setup.sh),
# so there is no Compose file for this line: one container, started with `docker run`.
#
# Settings come from /etc/famhomebase/famhomebase.env and the version from the VERSION file next to this script, which a release
# keeps equal to the image's tag:
#   FAMHOMEBASE_API_URL        where the cloud is, https://host with no path (default https://famhomebase.mc-esolutions.ca)
#   FAMHOMEBASE_ENV            prod or staging (default prod; staging shows a STAGING banner)
#   FAMHOMEBASE_PORT           the port, on this machine (default 80)
#   FAMHOMEBASE_BIND           the address it listens on (default 127.0.0.1: only this machine can reach it; 0.0.0.0 only to look at
#                              the display from another computer while testing)
#   FAMHOMEBASE_IMAGE          the image, without a tag (default ghcr.io/mcesolutionsinc/famhomebase-pi)
# The container's own start-up refuses a bad API address with one JSON line saying why.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="${FAMHOMEBASE_ETC_DIR:-/etc/famhomebase}/famhomebase.env"
STATE_DIR="${FAMHOMEBASE_STATE_DIR:-/var/lib/famhomebase}"
DOCKER=${DOCKER:-docker}
NAME=famhomebase-display

jlog() { printf '{"ts":"%s","level":"%s","component":"run","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | tr '"\\' "'/")"; }
# a value as written in the settings file: a Windows line ending and one pair of quotes around it are not part of it
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -e "s/^\"\\(.*\\)\"\$/\\1/" -e "s/^'\\(.*\\)'\$/\\1/"; }

VERSION=$(tr -d ' \r\n' < "$HERE/VERSION" 2>/dev/null || true)
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { jlog error "VERSION in $HERE is not a version like 0.1.0 (got '$VERSION')"; exit 1; }

PORT=$(getenv FAMHOMEBASE_PORT); PORT=${PORT:-80}
echo "$PORT" | grep -Eq '^[0-9]+$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { jlog error "FAMHOMEBASE_PORT '$PORT' is not a port number"; exit 1; }
BIND=$(getenv FAMHOMEBASE_BIND); BIND=${BIND:-127.0.0.1}
echo "$BIND" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && ! echo "$BIND" | tr . '\n' | grep -Eq '^(25[6-9]|2[6-9][0-9]|[3-9][0-9][0-9])$' || { jlog error "FAMHOMEBASE_BIND '$BIND' is not an IPv4 address like 127.0.0.1"; exit 1; }
API=$(getenv FAMHOMEBASE_API_URL); API=${API:-https://famhomebase.mc-esolutions.ca}
ENVNAME=$(getenv FAMHOMEBASE_ENV); ENVNAME=${ENVNAME:-prod}
case "$ENVNAME" in prod|staging) ;; *) jlog error "FAMHOMEBASE_ENV must be prod or staging (got '$ENVNAME')"; exit 1 ;; esac
IMAGE=$(getenv FAMHOMEBASE_IMAGE); IMAGE=${IMAGE:-ghcr.io/mcesolutionsinc/famhomebase-pi}

jlog info "starting $IMAGE:$VERSION on $BIND:$PORT for $ENVNAME ($API)"
# a leftover from a crash or an update would hold the name
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true
# 127.0.0.1, not localhost: in the Alpine nginx image localhost can resolve to ::1 first and nginx listens on IPv4 only.
# The state folder is shared with the container as /state: the page tells its web server how the screen is mounted, and the web server
# keeps that in a file there for the boot splash (see splash.sh).
mkdir -p "$STATE_DIR/state" 2>/dev/null
exec "$DOCKER" run --rm --name "$NAME" -p "$BIND:$PORT:8080" -v "$STATE_DIR/state:/state" \
  -e "FAMHOMEBASE_API_URL=$API" -e "FAMHOMEBASE_ENV=$ENVNAME" \
  --health-cmd "wget -qO- http://127.0.0.1:8080/runtime-config.json" \
  --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 10s \
  "$IMAGE:$VERSION"
