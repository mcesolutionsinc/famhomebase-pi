#!/bin/sh
# Updates the FamHomeBase cloud display. Run by the famhomebase-cloud-update systemd timer (as root), every few hours; also fine by hand:
#   sudo sh scripts/cloud-update.sh
#
# A release is the container image AND a payload of host files (scripts, the units' text, docs) with the same version number. This
# script looks for a newer cloud-vX.Y.Z release of famhomebase-pi, downloads the payload and checks its sha256, pulls the image, saves
# the current files, swaps the new ones in, has cloud-host-setup.sh apply them to this machine, waits for the display to be healthy,
# and puts everything back if it isn't. Your .env is never touched. AUTO_UPDATE=false in .env only logs that a release is available.
set -u

# This script is replaced by the very update it applies, and a shell reads its script as it runs: run from a copy.
if [ -z "${FAMHOMEBASE_UPDATER_COPY:-}" ]; then
  copy=$(mktemp) && cp "$0" "$copy" && FAMHOMEBASE_UPDATER_COPY=1 FAMHOMEBASE_UPDATER_ORIG="$0" exec sh "$copy" "$@"
fi
ORIG=${FAMHOMEBASE_UPDATER_ORIG:-$0}
tmp=""
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp"; [ -n "${FAMHOMEBASE_UPDATER_ORIG:-}" ] && rm -f "$0"; return 0; }
trap cleanup EXIT

REPO="${FAMHOMEBASE_REPO:-mcesolutionsinc/famhomebase-pi}"
API="${GITHUB_API:-https://api.github.com}"
DL="${GITHUB_DOWNLOAD:-https://github.com}"
DIR="${FAMHOMEBASE_DIR:-$(cd "$(dirname "$ORIG")/.." && pwd)}"
DOCKER="${DOCKER:-docker}"
CURL="${CURL:-curl}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT_SECONDS:-240}"
HEALTH_POLL="${HEALTH_POLL_SECONDS:-5}"
RETRY_AFTER_FAILURE="${RETRY_AFTER_FAILURE_SECONDS:-86400}"
NAME=famhomebase-display

# This script deletes and replaces folders under $DIR; never let that be empty or the filesystem root.
case "$DIR" in ""|"/") printf '{"level":"error","component":"cloud-update","msg":"FAMHOMEBASE_DIR must be the install folder"}\n' >&2; exit 1 ;; esac

jlog() { printf '{"ts":"%s","level":"%s","component":"cloud-update","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | tr '"\\' "'/")"; }
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$DIR/.env" 2>/dev/null | tail -n 1; }
is_semver() { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
current_version() { tr -d ' \r\n' < "$DIR/VERSION" 2>/dev/null; }

# $1 > $2, both x.y.z
ver_gt() {
  a1=${1%%.*}; r=${1#*.}; a2=${r%%.*}; a3=${r#*.}
  b1=${2%%.*}; r=${2#*.}; b2=${r%%.*}; b3=${r#*.}
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0
  [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ]
}

# The highest cloud-vX.Y.Z among the repo's releases, as x.y.z (the old line's v* releases and anything else are ignored: the repo's
# "latest" release belongs to that line, so it cannot be asked for).
latest_version() {
  body=$($CURL -fsSL "$API/repos/$REPO/releases?per_page=50" 2>/dev/null) || return 1
  best=""
  for v in $(echo "$body" | sed -n 's/.*"tag_name": *"cloud-v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p'); do
    if [ -z "$best" ] || ver_gt "$v" "$best"; then best=$v; fi
  done
  [ -n "$best" ] && echo "$best"
}

# A version that failed to come up is not retried for a day, so a bad release cannot make the display flap.
recently_failed() {
  [ -f "$DIR/.update-failed" ] || return 1
  read -r failed_ver failed_at < "$DIR/.update-failed" || return 1
  [ "$failed_ver" = "$1" ] && [ $(( $(date +%s) - failed_at )) -lt "$RETRY_AFTER_FAILURE" ]
}

health() { "$DOCKER" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$NAME" 2>/dev/null || echo missing; }
wait_healthy() {
  waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    [ "$(health)" = healthy ] && return 0
    sleep "$HEALTH_POLL"
    waited=$((waited + HEALTH_POLL))
  done
  return 1
}

# the files a release replaces; .env, .rollback and the like stay
SWAP_FILES="VERSION README.md LICENSE .env.example"
SWAP_DIRS="scripts docs"
restore_from() { # $1 = rollback dir
  for f in $SWAP_FILES; do [ -f "$1/$f" ] && cp -f "$1/$f" "$DIR/$f"; done
  for d in $SWAP_DIRS; do
    if [ -d "$1/$d" ]; then rm -rf "${DIR:?}/$d"; cp -r "$1/$d" "$DIR/$d"; fi
  done
}

# --- decide ------------------------------------------------------------------------------------------------------------------------
current=$(current_version)
is_semver "$current" || { jlog error "VERSION in $DIR is not a version (got '$current'): nothing to update from"; exit 1; }
latest=$(latest_version) || { jlog warn "could not look up the latest cloud release (offline?); will try again at the next check"; exit 0; }
is_semver "$latest" || { jlog warn "could not read the latest cloud release"; exit 0; }
if ! ver_gt "$latest" "$current"; then jlog info "up to date at $current"; exit 0; fi
if [ "$(getenv AUTO_UPDATE)" = false ]; then jlog info "release $latest is available (AUTO_UPDATE=false, so not installing)"; exit 0; fi
if recently_failed "$latest"; then jlog warn "$latest failed to start recently; not trying it again yet"; exit 0; fi

jlog info "updating $current to $latest"
tmp=$(mktemp -d)
pname="famhomebase-pi-cloud-$latest"
base="$DL/$REPO/releases/download/cloud-v$latest"

# --- download and check the payload ------------------------------------------------------------------------------------------------------
$CURL -fsSL -o "$tmp/$pname.tar.gz" "$base/$pname.tar.gz" && $CURL -fsSL -o "$tmp/$pname.tar.gz.sha256" "$base/$pname.tar.gz.sha256" \
  || { jlog error "could not download release $latest"; exit 1; }
expected=$(cut -d' ' -f1 < "$tmp/$pname.tar.gz.sha256")
actual=$(sha256sum "$tmp/$pname.tar.gz" | cut -d' ' -f1)
[ -n "$expected" ] && [ "$expected" = "$actual" ] || { jlog error "checksum mismatch for $latest: the download is damaged or not what was published; nothing was changed"; exit 1; }
mkdir -p "$tmp/new" && tar -xzf "$tmp/$pname.tar.gz" -C "$tmp/new" || { jlog error "could not unpack release $latest"; exit 1; }
[ "$(tr -d ' \r\n' < "$tmp/new/VERSION" 2>/dev/null)" = "$latest" ] && [ -f "$tmp/new/scripts/cloud-run.sh" ] && [ -f "$tmp/new/scripts/cloud-host-setup.sh" ] \
  || { jlog error "the payload is not a valid $latest release; nothing was changed"; exit 1; }

# --- the image first: if it cannot be pulled, nothing has changed -------------------------------------------------------------------------
image=$(getenv FAMHOMEBASE_CLOUD_IMAGE); image=${image:-ghcr.io/mcesolutionsinc/famhomebase-pi-cloud}
"$DOCKER" pull "$image:$latest" >/dev/null 2>&1 || { jlog error "could not pull $image:$latest (is the package public, and the release finished?); nothing was changed"; exit 1; }

# --- save, swap, apply ------------------------------------------------------------------------------------------------------------
rollback="$DIR/.rollback"
rm -rf "${rollback:?}"; mkdir -p "$rollback"
for f in $SWAP_FILES; do [ -f "$DIR/$f" ] && cp -f "$DIR/$f" "$rollback/$f"; done
for d in $SWAP_DIRS; do [ -d "$DIR/$d" ] && cp -r "$DIR/$d" "$rollback/$d"; done

fail() {
  jlog error "$1: putting the old version back"
  restore_from "$rollback"
  sh "$DIR/scripts/cloud-host-setup.sh" --update >/dev/null 2>&1
  printf '%s %s\n' "$latest" "$(date +%s)" > "$DIR/.update-failed"
  if wait_healthy; then jlog warn "back on $current and healthy"; else jlog error "the display is not healthy after going back to $current: see journalctl -u famhomebase-cloud"; fi
  exit 1
}

for f in $SWAP_FILES; do [ -f "$tmp/new/$f" ] && cp -f "$tmp/new/$f" "$DIR/$f"; done
for d in $SWAP_DIRS; do
  if [ -d "$tmp/new/$d" ]; then rm -rf "${DIR:?}/$d"; cp -r "$tmp/new/$d" "$DIR/$d"; fi
done
sh "$DIR/scripts/cloud-host-setup.sh" --update >/dev/null 2>&1 || fail "applying the new files to this machine failed"
wait_healthy || fail "the display did not become healthy within ${HEALTH_TIMEOUT}s"

rm -f "$DIR/.update-failed"
jlog info "updated $current to $latest"
exit 0
