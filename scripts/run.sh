#!/bin/sh
# Runs the FamHomeBase display container. This is what the famhomebase systemd unit starts (see host-setup.sh),
# so there is no Compose file for this line: one container, started with `docker run`.
#
# Settings come from .env (next to this folder) and the version from VERSION, which a release keeps equal to the image's tag:
#   FAMHOMEBASE_API_URL        where the cloud is, https://host with no path (default https://famhomebase.mc-esolutions.ca)
#   FAMHOMEBASE_ENV            prod or staging (default prod; staging shows a STAGING banner)
#   FAMHOMEBASE_PORT           the port you browse to (default 80)
#   FAMHOMEBASE_IMAGE          the image, without a tag (default ghcr.io/mcesolutionsinc/famhomebase-pi)
# The container's own start-up refuses a bad API address with one JSON line saying why.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
DIR=$(cd "$HERE/.." && pwd)
DOCKER=${DOCKER:-docker}
NAME=famhomebase-display

jlog() { printf '{"ts":"%s","level":"%s","component":"run","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | tr '"\\' "'/")"; }
# a value as written in .env: a Windows line ending and one pair of quotes around it are not part of it
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$DIR/.env" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -e "s/^\"\\(.*\\)\"\$/\\1/" -e "s/^'\\(.*\\)'\$/\\1/"; }

VERSION=$(tr -d ' \r\n' < "$DIR/VERSION" 2>/dev/null || true)
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { jlog error "VERSION in $DIR is not a version like 0.1.0 (got '$VERSION')"; exit 1; }

PORT=$(getenv FAMHOMEBASE_PORT); PORT=${PORT:-80}
echo "$PORT" | grep -Eq '^[0-9]+$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { jlog error "FAMHOMEBASE_PORT '$PORT' is not a port number"; exit 1; }
API=$(getenv FAMHOMEBASE_API_URL); API=${API:-https://famhomebase.mc-esolutions.ca}
ENVNAME=$(getenv FAMHOMEBASE_ENV); ENVNAME=${ENVNAME:-prod}
case "$ENVNAME" in prod|staging) ;; *) jlog error "FAMHOMEBASE_ENV must be prod or staging (got '$ENVNAME')"; exit 1 ;; esac
IMAGE=$(getenv FAMHOMEBASE_IMAGE); IMAGE=${IMAGE:-ghcr.io/mcesolutionsinc/famhomebase-pi}

jlog info "starting $IMAGE:$VERSION on port $PORT for $ENVNAME ($API)"
# a leftover from a crash or an update would hold the name
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true
# 127.0.0.1, not localhost: in the Alpine nginx image localhost can resolve to ::1 first and nginx listens on IPv4 only.
exec "$DOCKER" run --rm --name "$NAME" -p "$PORT:8080" \
  -e "FAMHOMEBASE_API_URL=$API" -e "FAMHOMEBASE_ENV=$ENVNAME" \
  --health-cmd "wget -qO- http://127.0.0.1:8080/runtime-config.json" \
  --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 10s \
  "$IMAGE:$VERSION"
