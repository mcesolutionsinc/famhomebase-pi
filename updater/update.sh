#!/bin/sh
# FamHomeBase updater — runs in the `updater` service of docker-compose.yml (image docker:27-cli: busybox + docker CLI
# + compose, nothing else, so this is plain POSIX sh using only busybox tools).
#
# Every few hours it asks GitHub for the latest release of famhomebase-pi. If that is newer than ./VERSION it downloads
# the release payload, checks its sha256, swaps in the new compose file / scripts, pulls the pinned images, restarts the
# app and sidecar, waits for them to be healthy, and rolls back if they are not. Your ./data, ./secrets and ./.env are
# never touched. Set AUTO_UPDATE=false in .env to be told about new releases (in this service's log) without installing.
#
#   update.sh           run forever (what the service does)
#   update.sh --once    check (and apply) once, then exit — handy for testing: docker compose run --rm updater sh ./updater/update.sh --once
set -u

# This script is replaced by the very update it applies, and a shell reads its script as it runs — so run from a copy.
if [ -z "${FAMHOMEBASE_UPDATER_COPY:-}" ]; then
  cp "$0" /tmp/update.sh && FAMHOMEBASE_UPDATER_COPY=1 exec sh /tmp/update.sh "$@"
fi

REPO="${FAMHOMEBASE_REPO:-mcesolutionsinc/famhomebase-pi}"
API="${GITHUB_API:-https://api.github.com}"
DL="${GITHUB_DOWNLOAD:-https://github.com}"
DIR="${FAMHOMEBASE_DIR:-$(pwd)}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
INTERVAL_HOURS="${CHECK_INTERVAL_HOURS:-6}"
FIRST_DELAY="${FIRST_CHECK_DELAY_SECONDS:-300}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT_SECONDS:-240}"
HEALTH_POLL="${HEALTH_POLL_SECONDS:-5}"
RETRY_AFTER_FAILURE="${RETRY_AFTER_FAILURE_SECONDS:-86400}"
DOCKER="${DOCKER:-docker}"
WGET="${WGET:-wget}"

# This script deletes and replaces folders under $DIR; never let that be empty or the filesystem root.
case "$DIR" in
  ""|"/") echo "[updater] FAMHOMEBASE_DIR must be the full path of the install folder (got '$DIR'); refusing to run" >&2; exit 1 ;;
esac

log() { echo "[updater] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

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

is_semver() { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

current_version() { tr -d ' \r\n' < "$DIR/VERSION" 2>/dev/null; }

# The newest published (non-draft, non-prerelease) release, as x.y.z; empty if it can't be found or isn't a plain vX.Y.Z tag.
latest_version() {
  body=$($WGET -qO- "$API/repos/$REPO/releases/latest" 2>/dev/null) || return 1
  tag=$(echo "$body" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  case "$tag" in v*) ver=${tag#v} ;; *) return 1 ;; esac
  is_semver "$ver" || return 1
  echo "$ver"
}

# A version that failed to come up is not retried for RETRY_AFTER_FAILURE seconds, so a bad release can't flap the dashboard.
recently_failed() {
  [ -f "$DIR/.update-failed" ] || return 1
  read -r failed_ver failed_at < "$DIR/.update-failed" || return 1
  [ "$failed_ver" = "$1" ] && [ $(( $(date +%s) - failed_at )) -lt "$RETRY_AFTER_FAILURE" ]
}

health_of() {
  id=$($DOCKER compose ps -q "$1" 2>/dev/null | head -n 1)
  [ -n "$id" ] || { echo missing; return; }
  $DOCKER inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo missing
}

wait_healthy() {
  waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if [ "$(health_of configstore)" = healthy ] && [ "$(health_of app)" = healthy ]; then return 0; fi
    sleep "$HEALTH_POLL"
    waited=$((waited + HEALTH_POLL))
  done
  return 1
}

restore_from() { # $1 = rollback dir
  for f in docker-compose.yml VERSION README.md LICENSE; do [ -f "$1/$f" ] && cp -f "$1/$f" "$DIR/$f"; done
  for d in scripts updater docs; do
    if [ -d "$1/$d" ]; then rm -rf "${DIR:?}/$d"; cp -r "$1/$d" "$DIR/$d"; fi
  done
}

fix_owner() {
  owner=$(stat -c '%u:%g' "$DIR" 2>/dev/null) || return 0
  for f in docker-compose.yml VERSION README.md LICENSE scripts updater docs .update-failed .last-update .update-available; do
    [ -e "$DIR/$f" ] && chown -R "$owner" "$DIR/$f" 2>/dev/null
  done
  return 0
}

apply_update() { # $1 = new version (x.y.z)
  ver=$1
  stage=$(mktemp -d) || return 1
  name="famhomebase-pi-$ver"
  base="$DL/$REPO/releases/download/v$ver"

  log "downloading $name"
  $WGET -q -O "$stage/$name.tar.gz" "$base/$name.tar.gz" || { log "download failed"; rm -rf "$stage"; return 1; }
  $WGET -q -O "$stage/$name.tar.gz.sha256" "$base/$name.tar.gz.sha256" || { log "checksum download failed"; rm -rf "$stage"; return 1; }
  expected=$(cut -d' ' -f1 < "$stage/$name.tar.gz.sha256")
  actual=$(sha256sum "$stage/$name.tar.gz" | cut -d' ' -f1)
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    log "checksum mismatch — refusing to install"
    rm -rf "$stage"
    return 1
  fi

  mkdir "$stage/new" && tar -xzf "$stage/$name.tar.gz" -C "$stage/new" || { log "could not unpack"; rm -rf "$stage"; return 1; }
  if [ ! -f "$stage/new/docker-compose.yml" ] || [ "$(tr -d ' \r\n' < "$stage/new/VERSION" 2>/dev/null)" != "$ver" ]; then
    log "payload is not a valid $ver release — refusing to install"
    rm -rf "$stage"
    return 1
  fi

  rollback="$DIR/.rollback"
  rm -rf "${rollback:?}"; mkdir -p "$rollback"
  for f in docker-compose.yml VERSION README.md LICENSE; do [ -f "$DIR/$f" ] && cp -f "$DIR/$f" "$rollback/$f"; done
  for d in scripts updater docs; do [ -d "$DIR/$d" ] && cp -r "$DIR/$d" "$rollback/$d"; done

  log "installing files for $ver (data, secrets and .env are left alone)"
  restore_from "$stage/new"
  fix_owner

  cd "$DIR" || return 1
  log "pulling images"
  if ! $DOCKER compose pull app configstore; then
    log "pull failed — putting the previous release's files back (nothing was restarted)"
    restore_from "$rollback"; fix_owner
    rm -rf "$stage"
    return 1
  fi

  log "restarting the dashboard on $ver"
  $DOCKER compose up -d app configstore
  if wait_healthy; then
    log "$ver is healthy"
  else
    log "$ver did not become healthy within ${HEALTH_TIMEOUT}s — rolling back"
    restore_from "$rollback"; fix_owner
    $DOCKER compose up -d app configstore
    echo "$ver $(date +%s)" > "$DIR/.update-failed"; fix_owner
    rm -rf "$stage"
    return 1
  fi

  echo "$ver $(date '+%Y-%m-%d %H:%M:%S')" > "$DIR/.last-update"
  rm -f "$DIR/.update-failed" "$DIR/.update-available"
  fix_owner
  rm -rf "$stage"

  # This service may itself have changed in the new compose file. Recreating it from here would stop the very process
  # doing the recreating, so hand the job to a throwaway container of the same image that outlives us.
  image=$($DOCKER inspect -f '{{.Config.Image}}' "$(hostname)" 2>/dev/null)
  if [ -n "$image" ]; then
    $DOCKER run -d --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$DIR:$DIR" -w "$DIR" "$image" \
      sh -c 'sleep 5; docker compose up -d updater' >/dev/null 2>&1 || true
  fi
  return 0
}

check_once() {
  current=$(current_version)
  if [ -z "$current" ] || ! is_semver "$current"; then
    log "this is a development checkout (VERSION='${current}'), not a release install — not updating"
    return 0
  fi
  latest=$(latest_version) || { log "could not read the latest release from GitHub (offline?) — will try again later"; return 0; }
  if ! ver_gt "$latest" "$current"; then
    log "up to date ($current)"
    return 0
  fi
  if recently_failed "$latest"; then
    log "$latest failed to start recently — skipping it for now"
    return 0
  fi
  if [ "$AUTO_UPDATE" != "true" ]; then
    log "release $latest is available (you have $current); auto-update is off"
    echo "$latest" > "$DIR/.update-available"; fix_owner
    return 0
  fi
  log "release $latest is available (you have $current)"
  apply_update "$latest" || log "update to $latest did not complete; staying on $current"
}

if [ "${1:-}" = "--once" ]; then
  check_once
  exit 0
fi

log "started: watching $REPO (every ${INTERVAL_HOURS}h, auto-update: $AUTO_UPDATE, install dir: $DIR)"
sleep "$FIRST_DELAY"
while true; do
  check_once
  sleep $((INTERVAL_HOURS * 3600))
done
