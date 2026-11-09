#!/bin/sh
# Waits until the display's page is being served (or gives up after a while), then exits 0 either way. The famhomebase-ready service runs it,
# and plymouth (the boot splash) is told to wait for that service, so the splash stays on the screen until the kiosk has something to show
# instead of leaving a blank screen while the container starts.
#
# Reads from /etc/famhomebase/famhomebase.env: FAMHOMEBASE_PORT (default 80). FAMHOMEBASE_READY_SECONDS (default 90) is how long to wait.
set -u

ENV_FILE="${FAMHOMEBASE_ETC_DIR:-/etc/famhomebase}/famhomebase.env"
CURL=${CURL:-curl}
SLEEP=${SLEEP:-sleep}
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d '\r'; }
jlog() { printf '{"ts":"%s","level":"%s","component":"ready","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | tr '"\\' "'/")"; }

PORT=$(getenv FAMHOMEBASE_PORT)
case "$PORT" in ''|*[!0-9]*) PORT=80 ;; esac
LIMIT=${FAMHOMEBASE_READY_SECONDS:-90}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=90 ;; esac

waited=0
until "$CURL" -sf -o /dev/null "http://127.0.0.1:$PORT/"; do
  if [ "$waited" -ge "$LIMIT" ]; then jlog warn "the page was not being served after ${LIMIT}s: going on without it"; exit 0; fi
  "$SLEEP" 1
  waited=$((waited + 1))
done
jlog info "the page is being served (after ${waited}s)"
exit 0
