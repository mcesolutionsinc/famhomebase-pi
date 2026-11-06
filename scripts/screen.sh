#!/bin/sh
# Turns this Pi's screen off at night, and back on in the morning, when "Night mode → the Pi's screen turns off" is chosen in
# the dashboard's Settings. Started by scripts/kiosk.sh and stopped with it (they share the kiosk service), so an update that
# replaces these scripts is all it takes. It only ever reads the dashboard's settings — the schedule is the same "dim from /
# back to normal at" times, in the household's timezone.
#
# Reads from .env (next to this folder):
#   FAMHOMEBASE_PORT     the port the dashboard is on (default 80)
#   FAMHOMEBASE_OUTPUT   which display to switch, e.g. HDMI-A-1. Unset = the first one `wlr-randr` lists.
# Checks every 30 seconds. If the dashboard can't be reached it leaves the screen as it is. Needs wlopm (Raspberry Pi OS
# desktop has it); without it, night mode still dims the dashboard and this exits quietly.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$HERE/../.env"
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$ENV_FILE" 2>/dev/null | tail -n 1; }

PORT=$(getenv FAMHOMEBASE_PORT)
case "$PORT" in ''|*[!0-9]*) PORT=80 ;; esac
OUTPUT=$(getenv FAMHOMEBASE_OUTPUT)
if [ "$PORT" = 80 ]; then URL=http://localhost; else URL="http://localhost:$PORT"; fi
MAX_TICKS=${FAMHOMEBASE_SCREEN_MAX_TICKS:-0} # 0 = run forever; the tests set a number

XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export XDG_RUNTIME_DIR WAYLAND_DISPLAY

command -v wlopm >/dev/null 2>&1 || { echo "screen: wlopm is not installed (sudo apt install wlopm), so the screen will not turn off at night" >&2; exit 0; }

# "HH:MM" -> minutes since midnight; empty if it isn't one.
minutes() {
  case "$1" in
    [0-2][0-9]:[0-5][0-9])
      h=${1%:*}; m=${1#*:}
      h=${h#0}; m=${m#0} # no leading zero, which sh arithmetic would read as octal
      echo $(( ${h:-0} * 60 + ${m:-0} )) ;;
    *) echo "" ;;
  esac
}

# Prints "off" when the screen should be off right now, "on" when it should be on, nothing when it can't tell.
wanted() {
  cfg=$(curl -sf -m 5 "$URL/api/config") || return 0
  appearance=$(printf '%s' "$cfg" | grep -o '"appearance":{[^}]*}')
  display=$(printf '%s' "$cfg" | grep -o '"display":{[^}]*}')
  [ -n "$display" ] || return 0
  case "$appearance" in
    *'"nightMode":true'*'"nightScreen":"off"'*|*'"nightScreen":"off"'*'"nightMode":true'*) ;;
    *) echo on; return 0 ;;
  esac
  off=$(minutes "$(printf '%s' "$display" | sed -n 's/.*"screenOffTime":"\([^"]*\)".*/\1/p')")
  on=$(minutes "$(printf '%s' "$display" | sed -n 's/.*"screenOnTime":"\([^"]*\)".*/\1/p')")
  tz=$(printf '%s' "$display" | sed -n 's/.*"timezone":"\([^"]*\)".*/\1/p')
  if [ -n "$tz" ]; then now=$(TZ="$tz" date +%H:%M); else now=$(date +%H:%M); fi
  now=$(minutes "$now")
  if [ -z "$off" ] || [ -z "$on" ] || [ -z "$now" ] || [ "$off" = "$on" ]; then echo on; return 0; fi
  if [ "$off" -lt "$on" ]; then
    if [ "$now" -ge "$off" ] && [ "$now" -lt "$on" ]; then echo off; else echo on; fi
  else
    if [ "$now" -ge "$off" ] || [ "$now" -lt "$on" ]; then echo off; else echo on; fi
  fi
}

output() {
  if [ -n "$OUTPUT" ]; then echo "$OUTPUT"; return; fi
  wlr-randr 2>/dev/null | awk '/^[^ ]/ { print $1; exit }'
}

last=""
ticks=0
while :; do
  state=$(wanted)
  if [ -n "$state" ] && [ "$state" != "$last" ]; then
    out=$(output)
    if [ -n "$out" ] && wlopm "--$state" "$out"; then
      last=$state
      echo "screen: turned $out $state"
    else
      echo "screen: could not turn the screen $state" >&2
    fi
  fi
  ticks=$((ticks + 1))
  [ "$MAX_TICKS" -gt 0 ] && [ "$ticks" -ge "$MAX_TICKS" ] && break
  sleep 30
done
