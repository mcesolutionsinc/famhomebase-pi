#!/bin/sh
# The first-boot update (ticket 58): on the very first boot of a display, install the newest release before the pairing screen is shown, so
# a freshly flashed card is not paired on an old build. Run once, as root, by the famhomebase-first-update systemd unit, which is ordered
# after the display starts and before the boot splash leaves, so the whole time is spent behind the splash. While an update really is being
# installed the splash says "Updating" under its dots (plymouth display-message). It changes nothing about any later update: the update
# timer and scripts/update.sh (checksum, pull first, back up, swap, wait healthy, roll back) are used exactly as they are.
#
# What it does, and what is left behind in $STATE_DIR/first-boot-update-done (one word and a time), so it never runs twice:
#   no network (or no right clock for TLS) within FAMHOMEBASE_FIRST_UPDATE_NET_SECONDS (60)  -> offline: the screen goes on at once
#   update.sh installed a newer release                                                       -> updated
#   already the newest                                                                         -> up-to-date
#   AUTO_UPDATE is off in the settings                                                         -> disabled
#   not done within 15 minutes and still downloading                                          -> timeout
#   anything else (the update failed and was rolled back, or a version that failed recently)  -> failed
# It never fails the boot: every way out is exit 0, and the screen is never left on "Updating". It gives the update 15 minutes
# (FAMHOMEBASE_FIRST_UPDATE_LIMIT_SECONDS): if update.sh is still downloading then, it is stopped (nothing has changed yet) and the word is "timeout";
# if it has started swapping files it is let finish (it ends itself within minutes, rolling back if it must), because stopping it half way would leave
# the install half changed. The unit's own 25-minute limit is only a last resort: it runs this script again with --after-stop, which writes "timeout".
# A power cut leaves no word, so the next boot tries again. The normal timer retries whatever was skipped.
#
# While it runs, $RUN_DIR/first-boot-update exists: host-setup.sh (run by the update) then does not restart the kiosk, which would start the
# screen in the middle of the update. The kiosk starts by itself once the splash leaves.
#
# Where things are (the tests move them with these variables): FAMHOMEBASE_LIB_DIR (update.sh and VERSION), FAMHOMEBASE_STATE_DIR,
# FAMHOMEBASE_RUN_DIR, GITHUB_API.
set -u

# update.sh replaces the folder this script lives in, and a shell reads its script as it runs: run from a copy.
if [ -z "${FAMHOMEBASE_FIRST_UPDATE_COPY:-}" ]; then
  copy=$(mktemp) && cp "$0" "$copy" && FAMHOMEBASE_FIRST_UPDATE_COPY=1 FAMHOMEBASE_FIRST_UPDATE_ORIG="$0" exec sh "$copy" "$@"
fi
ORIG=${FAMHOMEBASE_FIRST_UPDATE_ORIG:-$0}

LIB_DIR="${FAMHOMEBASE_LIB_DIR:-$(cd "$(dirname "$ORIG")" && pwd)}"
STATE_DIR="${FAMHOMEBASE_STATE_DIR:-/var/lib/famhomebase}"
RUN_DIR="${FAMHOMEBASE_RUN_DIR:-/run/famhomebase}"
MARKER="$STATE_DIR/first-boot-update-done"
FLAG="$RUN_DIR/first-boot-update"
API="${GITHUB_API:-https://api.github.com}"
CURL="${CURL:-curl}"
SLEEP="${SLEEP:-sleep}"
PLYMOUTH="${PLYMOUTH:-plymouth}"
NET_SECONDS="${FAMHOMEBASE_FIRST_UPDATE_NET_SECONDS:-60}"
case "$NET_SECONDS" in ''|*[!0-9]*) NET_SECONDS=60 ;; esac
LIMIT_SECONDS="${FAMHOMEBASE_FIRST_UPDATE_LIMIT_SECONDS:-900}"
case "$LIMIT_SECONDS" in ''|*[!0-9]*) LIMIT_SECONDS=900 ;; esac
UPTIME_FILE="${FAMHOMEBASE_PROC_UPTIME:-/proc/uptime}"

log=""; watcher=""
cleanup() {
  [ -n "$watcher" ] && kill "$watcher" >/dev/null 2>&1
  [ -n "$log" ] && rm -f "$log" "$log.done" "$log.start" "$log.timeout"
  rm -f "$FLAG"
  [ -n "${FAMHOMEBASE_FIRST_UPDATE_ORIG:-}" ] && rm -f "$0"
  return 0
}
trap cleanup EXIT

jlog() { printf '{"ts":"%s","level":"%s","component":"first-update","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | tr '"\\' "'/")"; }
mark() { mkdir -p "$STATE_DIR" && printf '%s %s\n' "$1" "$(date +%s)" > "$MARKER"; }
version() { tr -d ' \r\n' < "$LIB_DIR/VERSION" 2>/dev/null; }
# Seconds since the machine started, for every wait below: the clock of a Pi with no battery is set by the network a few seconds after the boot,
# and it steps by months when it is, which would make a wall-clock wait look as if it had run out. (The date is the fallback only.)
now_s() { if read -r up _ < "$UPTIME_FILE" 2>/dev/null; then echo "${up%%.*}"; else date +%s; fi; }
# the word under the splash's dots: $1 = display-message or hide-message. Nothing to do (and nothing to fail) where there is no splash.
splash_word() { "$PLYMOUTH" --ping >/dev/null 2>&1 || return 0; "$PLYMOUTH" "$1" --text=updating >/dev/null 2>&1 || true; }

# run by the unit after it stops, however it stopped (ExecStopPost): if systemd had to end it (the 15 minutes) no word was written, so one is, and
# the flag is taken away (a killed shell does not clean up). After a power cut this never runs, so the next boot tries again.
if [ "${1:-}" = "--after-stop" ]; then
  rm -f "$FLAG"
  if [ ! -e "$MARKER" ]; then mark timeout; jlog warn "the first-boot update was stopped before it finished: going on without it (the normal update will do it)"; fi
  exit 0
fi

if [ -f "$MARKER" ]; then jlog info "already done ($(cut -d' ' -f1 "$MARKER" 2>/dev/null)): nothing to do"; exit 0; fi

mkdir -p "$RUN_DIR" && : > "$FLAG"

# a network, and a clock right enough for the TLS to the release server (a Pi has no clock of its own until it has asked the network)
start=$(now_s)
until "$CURL" -sf --max-time 5 -o /dev/null "$API/"; do
  if [ $(( $(now_s) - start )) -ge "$NET_SECONDS" ]; then
    jlog warn "no network after ${NET_SECONDS}s: going on without the update (the pairing screen shows this version, and the normal update does it later)"
    mark offline
    exit 0
  fi
  "$SLEEP" 1
done

before=$(version)
log=$(mktemp) || { jlog error "could not make a scratch file: going on without the update"; mark failed; exit 0; }

# The word is shown when update.sh says it is installing a release ("updating X to Y"): looking up and finding nothing newer is quick, and flashes
# nothing. The updater runs in the background and a watcher looks at its lines (and at the clock: see the header for the 15 minutes); this shell waits
# for the updater, so its result is this shell's. The watcher ends when the updater is done, or if this shell is gone.
: > "$log.start"
began=$(now_s)
sh "$LIB_DIR/update.sh" > "$log" 2>&1 &
updater=$!
parent=$$
(
  shown=0
  while [ ! -e "$log.done" ] && kill -0 "$parent" 2>/dev/null; do
    if [ "$shown" -eq 0 ] && grep -q '"msg":"updating ' "$log" 2>/dev/null; then
      splash_word display-message
      shown=1
      jlog info "installing a newer release: the splash says Updating"
    fi
    if [ $(( $(now_s) - began )) -ge "$LIMIT_SECONDS" ] && [ ! -e "$log.timeout" ]; then
      # past the time: stop the updater while it is only downloading; once it has saved the old files and started swapping (the folder it saves
      # them in is newer than the start) let it finish, as it puts the old version back itself if the new one does not come up
      if find "$STATE_DIR/rollback" -maxdepth 0 -newer "$log.start" 2>/dev/null | grep -q .; then
        :
      else
        : > "$log.timeout"
        jlog warn "the update is not done after ${LIMIT_SECONDS}s: stopping it (nothing has been changed yet); the normal update will do it"
        kill "$updater" >/dev/null 2>&1
      fi
    fi
    "$SLEEP" 1
  done
) &
watcher=$!

wait "$updater" 2>/dev/null
: > "$log.done"
wait "$watcher" 2>/dev/null; watcher=""
cat "$log" # the updater's own lines, as it wrote them, into the journal
splash_word hide-message

after=$(version)
if [ -e "$log.timeout" ]; then outcome="timeout"
elif [ "$after" != "$before" ]; then outcome="updated"
elif grep -q 'up to date' "$log"; then outcome="up-to-date"
elif grep -qE 'could not look up the latest|could not read the latest' "$log"; then outcome="offline"
elif grep -q 'AUTO_UPDATE is off' "$log"; then outcome="disabled"
else outcome="failed"; fi
mark "$outcome"
jlog info "first-boot update: $outcome (was $before, now $after)"
exit 0
