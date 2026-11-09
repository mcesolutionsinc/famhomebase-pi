#!/bin/sh
# Updates the FamHomeBase display. Run by the famhomebase-update systemd timer (as root), every few hours; also fine by hand:
#   sudo sh scripts/update.sh
#
# A release is the container image AND a payload of host files (scripts, the units' text, docs) with the same version number. This
# script looks for a newer vX.Y.Z release of famhomebase-pi, downloads the payload and checks its sha256, pulls the image, saves
# the current files, swaps the new ones in, has host-setup.sh apply them to this machine, waits for the display to be healthy,
# and puts everything back if it isn't. Your settings (/etc/famhomebase/famhomebase.env) are never touched. AUTO_UPDATE=false there
# only logs that a release is available.
#
# Where things are (each can be moved with an environment variable, which the tests do):
#   FAMHOMEBASE_LIB_DIR    /usr/local/lib/famhomebase       the scripts and VERSION (this script lives here)
#   FAMHOMEBASE_DOC_DIR    /usr/local/share/doc/famhomebase  README, licence, INSTALL, TROUBLESHOOTING
#   FAMHOMEBASE_ETC_DIR    /etc/famhomebase                 famhomebase.env (yours) and famhomebase.env.example (the release's)
#   FAMHOMEBASE_STATE_DIR  /var/lib/famhomebase             the saved copy for a way back, the failed-version note, the kiosk profile
# A release's payload has the same shape: lib/, doc/, famhomebase.env.example and VERSION. (It is lib/ and not scripts/ on purpose: the
# update script of a release before 0.3.0 looks for scripts/run.sh, finds none, and leaves that install alone instead of half-applying a
# layout it does not know.)
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
LIB_DIR="${FAMHOMEBASE_LIB_DIR:-$(cd "$(dirname "$ORIG")" && pwd)}"
DOC_DIR="${FAMHOMEBASE_DOC_DIR:-/usr/local/share/doc/famhomebase}"
ETC_DIR="${FAMHOMEBASE_ETC_DIR:-/etc/famhomebase}"
STATE_DIR="${FAMHOMEBASE_STATE_DIR:-/var/lib/famhomebase}"
ENV_FILE="$ETC_DIR/famhomebase.env"
DOCKER="${DOCKER:-docker}"
CURL="${CURL:-curl}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT_SECONDS:-240}"
HEALTH_POLL="${HEALTH_POLL_SECONDS:-5}"
RETRY_AFTER_FAILURE="${RETRY_AFTER_FAILURE_SECONDS:-86400}"
NAME=famhomebase-display

# This script deletes and replaces these folders; never let one be empty or the filesystem root.
for d in "$LIB_DIR" "$DOC_DIR" "$ETC_DIR" "$STATE_DIR"; do
  case "$d" in ""|"/") printf '{"level":"error","component":"update","msg":"an install folder is empty or the filesystem root"}\n' >&2; exit 1 ;; esac
done

jlog() { printf '{"ts":"%s","level":"%s","component":"update","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | tr '"\\' "'/")"; }
# a value as written in the settings file: a Windows line ending and one pair of quotes around it are not part of it
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -e "s/^\"\\(.*\\)\"\$/\\1/" -e "s/^'\\(.*\\)'\$/\\1/"; }
is_semver() { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
current_version() { tr -d ' \r\n' < "$LIB_DIR/VERSION" 2>/dev/null; }

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

# The highest vX.Y.Z among the repo's releases, as x.y.z (a release candidate, `nightly` and anything else that is not a plain version is ignored).
latest_version() {
  body=$($CURL -fsSL "$API/repos/$REPO/releases?per_page=100" 2>/dev/null) || return 1
  best=""
  for v in $(echo "$body" | grep -o '"tag_name": *"v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' | sed 's/.*"v\([0-9.]*\)"/\1/'); do
    if [ -z "$best" ] || ver_gt "$v" "$best"; then best=$v; fi
  done
  [ -n "$best" ] && echo "$best"
}

# A version that failed to come up is not retried for a day, so a bad release cannot make the display flap.
recently_failed() {
  [ -f "$STATE_DIR/update-failed" ] || return 1
  read -r failed_ver failed_at < "$STATE_DIR/update-failed" || return 1
  # a half-written file (a power cut) is no record at all: it must not stop the script
  case "$failed_at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$failed_ver" = "$1" ] && [ $(( $(date +%s) - failed_at )) -lt "$RETRY_AFTER_FAILURE" ]
}

# The display's state, but only if what is running is the version asked about: a restart that silently failed leaves the OLD container
# running and healthy, which must not count as the new version coming up.
health() { # $1 = the version that should be running
  image=$("$DOCKER" inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null) || { echo missing; return; }
  case "$image" in *":$1") ;; *) echo "other-version"; return ;; esac
  "$DOCKER" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$NAME" 2>/dev/null || echo missing
}
wait_healthy() { # $1 = the version that should be running
  waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    [ "$(health "$1")" = healthy ] && return 0
    sleep "$HEALTH_POLL"
    waited=$((waited + HEALTH_POLL))
  done
  return 1
}

# A payload (a release, or the saved copy of what was installed) is a folder shaped like the release: lib/, doc/,
# famhomebase.env.example and VERSION. apply puts one in place; snapshot makes one from what is installed now. Your settings file
# is not part of it. The files are root's (this runs as root and nothing here is in anyone's home folder).
apply() { # $1 = a payload folder
  rm -rf "${LIB_DIR:?}" "${DOC_DIR:?}" && mkdir -p "$LIB_DIR" "$DOC_DIR" "$ETC_DIR" || return 1
  cp -R "$1/lib/." "$LIB_DIR/" && cp -f "$1/VERSION" "$LIB_DIR/VERSION" || return 1
  [ -d "$1/doc" ] && cp -R "$1/doc/." "$DOC_DIR/"
  [ -f "$1/famhomebase.env.example" ] && cp -f "$1/famhomebase.env.example" "$ETC_DIR/famhomebase.env.example"
  return 0
}
snapshot() { # $1 = an empty folder to fill
  mkdir -p "$1/lib" "$1/doc"
  cp -R "$LIB_DIR/." "$1/lib/" && mv "$1/lib/VERSION" "$1/VERSION" || return 1
  [ -d "$DOC_DIR" ] && cp -R "$DOC_DIR/." "$1/doc/"
  [ -f "$ETC_DIR/famhomebase.env.example" ] && cp -f "$ETC_DIR/famhomebase.env.example" "$1/famhomebase.env.example"
  return 0
}

# --- decide ------------------------------------------------------------------------------------------------------------------------
current=$(current_version)
is_semver "$current" || { jlog error "VERSION in $LIB_DIR is not a version (got '$current'): nothing to update from"; exit 1; }
latest=$(latest_version) || { jlog warn "could not look up the latest release (offline?); will try again at the next check"; exit 0; }
is_semver "$latest" || { jlog warn "could not read the latest release"; exit 0; }
if ! ver_gt "$latest" "$current"; then jlog info "up to date at $current"; exit 0; fi
case "$(getenv AUTO_UPDATE | tr 'A-Z' 'a-z')" in false|0|no|off) auto=0 ;; *) auto=1 ;; esac
if [ "$auto" -eq 0 ]; then jlog info "release $latest is available (AUTO_UPDATE is off, so not installing)"; exit 0; fi
if recently_failed "$latest"; then jlog warn "$latest failed to start recently; not trying it again yet"; exit 0; fi

jlog info "updating $current to $latest"
tmp=$(mktemp -d)
pname="famhomebase-pi-$latest"
base="$DL/$REPO/releases/download/v$latest"

# --- download and check the payload ------------------------------------------------------------------------------------------------------
$CURL -fsSL -o "$tmp/$pname.tar.gz" "$base/$pname.tar.gz" && $CURL -fsSL -o "$tmp/$pname.tar.gz.sha256" "$base/$pname.tar.gz.sha256" \
  || { jlog error "could not download release $latest"; exit 1; }
expected=$(cut -d' ' -f1 < "$tmp/$pname.tar.gz.sha256")
actual=$(sha256sum "$tmp/$pname.tar.gz" | cut -d' ' -f1)
[ -n "$expected" ] && [ "$expected" = "$actual" ] || { jlog error "checksum mismatch for $latest: the download is damaged or not what was published; nothing was changed"; exit 1; }
mkdir -p "$tmp/new" && tar -xzf "$tmp/$pname.tar.gz" -C "$tmp/new" || { jlog error "could not unpack release $latest"; exit 1; }
[ "$(tr -d ' \r\n' < "$tmp/new/VERSION" 2>/dev/null)" = "$latest" ] && [ -f "$tmp/new/lib/run.sh" ] && [ -f "$tmp/new/lib/host-setup.sh" ] \
  || { jlog error "the payload is not a valid $latest release; nothing was changed"; exit 1; }

# --- the image first: if it cannot be pulled, nothing has changed -------------------------------------------------------------------------
image=$(getenv FAMHOMEBASE_IMAGE); image=${image:-ghcr.io/mcesolutionsinc/famhomebase-pi}
"$DOCKER" pull "$image:$latest" >/dev/null 2>&1 || { jlog error "could not pull $image:$latest (is the package public, and the release finished?); nothing was changed"; exit 1; }

# --- save, swap, apply ------------------------------------------------------------------------------------------------------------
rollback="$STATE_DIR/rollback"
rm -rf "${rollback:?}"; mkdir -p "$rollback"
snapshot "$rollback" || { jlog error "could not save the current files; nothing was changed"; exit 1; }

fail() {
  jlog error "$1: putting the old version back"
  apply "$rollback"
  # the old image is normally still here; if it was pruned in the meantime, fetch it again
  "$DOCKER" image inspect "$image:$current" >/dev/null 2>&1 || "$DOCKER" pull "$image:$current" >/dev/null 2>&1
  sh "$LIB_DIR/host-setup.sh" --update >/dev/null 2>&1
  printf '%s %s\n' "$latest" "$(date +%s)" > "$STATE_DIR/update-failed"
  if wait_healthy "$current"; then jlog warn "back on $current and healthy"; else jlog error "the display is not healthy after going back to $current: see journalctl -u famhomebase"; fi
  exit 1
}

apply "$tmp/new" || fail "putting the new files in place failed"
sh "$LIB_DIR/host-setup.sh" --update >/dev/null 2>&1 || fail "applying the new files to this machine failed"
wait_healthy "$latest" || fail "the display did not become healthy on $latest within ${HEALTH_TIMEOUT}s"

rm -f "$STATE_DIR/update-failed"
# keep this version and the one before (a way back); older images would fill the card over many releases
for tag in $("$DOCKER" images --format '{{.Tag}}' "$image" 2>/dev/null); do
  case "$tag" in "$latest"|"$current") ;; *) is_semver "$tag" && "$DOCKER" rmi "$image:$tag" >/dev/null 2>&1 ;; esac
done
jlog info "updated $current to $latest"
exit 0
