#!/bin/sh
# Tests for scripts/screen.sh with stubbed curl, date, wlopm, wlr-randr and sleep. Run: sh tests/test-screen.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
T="$WORK/inst"; BIN="$WORK/bin"; RT="$WORK/run"
mkdir -p "$T/scripts" "$BIN" "$RT" "$WORK/tools"
for tool in sed tail awk dirname grep printf cat tr; do p=$(command -v $tool) && ln -s "$p" "$WORK/tools/$tool"; done
cp "$HERE/../scripts/screen.sh" "$T/scripts/screen.sh"
LOG="$WORK/log"; CFG="$WORK/cfg.json"; NOW="$WORK/now"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
stub sleep ':'
stub id 'echo 1000'
stub curl 'if [ -f "$CFG" ]; then cat "$CFG"; else exit 22; fi'
stub date 'echo "date TZ=${TZ:-}" >> "$LOG"; cat "$NOW"'
stub wlopm 'echo "wlopm $*" >> "$LOG"'
stub wlr-randr 'echo "HDMI-A-1 \"Some Monitor\""; echo "  Modes:"; echo "DSI-1 \"Touch\""'

# The config the sidecar returns, as the app writes it (compact JSON).
config() { # nightMode nightScreen [off] [on] [tz]
  printf '{"schemaVersion":4,"widgets":[],"clockSettings":{"c":{"timezone":"Europe/London"}},"appearance":{"themeId":"x","nightMode":%s%s},"display":{"screenOnTime":"%s","timezone":"%s","screenOffTime":"%s","screenProfile":"p"}}' \
    "$1" "$( [ "$2" = - ] || printf ',"nightScreen":"%s"' "$2")" "${4:-06:30}" "${5:-America/Toronto}" "${3:-22:30}" > "$CFG"
}
run() { # time, then extra env
  printf '%s\n' "$1" > "$NOW"; shift
  : > "$LOG"
  env PATH="$BIN:$WORK/tools" XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY=wayland-0 LOG="$LOG" CFG="$CFG" NOW="$NOW" FAMHOMEBASE_SCREEN_MAX_TICKS=1 "$@" /bin/sh "$T/scripts/screen.sh" > "$WORK/out" 2>&1
}
rm -f "$T/.env"

config true off; run 23:15
check "night mode with 'turns off': off inside the window (past the off time, before midnight)" 'grep -q "^wlopm --off HDMI-A-1\$" "$LOG"'
run 02:00
check "off after midnight too (the window wraps)" 'grep -q "^wlopm --off HDMI-A-1\$" "$LOG"'
run 06:29
check "still off a minute before the on time" 'grep -q "^wlopm --off" "$LOG"'
run 06:30
check "on at exactly the on time" 'grep -q "^wlopm --on HDMI-A-1\$" "$LOG" && ! grep -q "^wlopm --off" "$LOG"'
run 14:00
check "on during the day" 'grep -q "^wlopm --on" "$LOG"'
run 22:30
check "off at exactly the off time" 'grep -q "^wlopm --off" "$LOG"'

config true off 01:00 05:00; run 03:00
check "a window that does not cross midnight: off inside it" 'grep -q "^wlopm --off" "$LOG"'
run 06:00
check "...and on outside it" 'grep -q "^wlopm --on" "$LOG"'
config true off 22:30 22:30; run 23:00
check "off time equal to on time: never off" 'grep -q "^wlopm --on" "$LOG"'
config true off 09:00 18:00; run 09:05
check "times with a leading zero are not read as octal (09:00)" 'grep -q "^wlopm --off" "$LOG"'

config true dim; run 23:15
check "night mode set to dim: the screen stays on (the browser does the dimming)" 'grep -q "^wlopm --on" "$LOG" && ! grep -q "^wlopm --off" "$LOG"'
config true -; run 23:15
check "no nightScreen choice (the default, dim): stays on" 'grep -q "^wlopm --on" "$LOG" && ! grep -q "^wlopm --off" "$LOG"'
config false off; run 23:15
check "night mode off, even with 'turns off' left behind: stays on" 'grep -q "^wlopm --on" "$LOG" && ! grep -q "^wlopm --off" "$LOG"'

config true off; run 23:15
check "the time is read in the household's timezone from the display settings, not the clock timezone setting" 'grep -q "^date TZ=America/Toronto\$" "$LOG" && ! grep -q "Europe/London" "$LOG"'

rm -f "$CFG"; run 23:15
check "the dashboard is not reachable: the screen is left alone" '! grep -q "^wlopm" "$LOG"'
printf 'not json' > "$CFG"; run 23:15
check "a reply with no settings in it: the screen is left alone" '! grep -q "^wlopm" "$LOG"'

printf 'FAMHOMEBASE_OUTPUT=DSI-1\n' > "$T/.env"; config true off; run 23:15
check "FAMHOMEBASE_OUTPUT picks the display" 'grep -q "^wlopm --off DSI-1\$" "$LOG"'
printf 'FAMHOMEBASE_PORT=8080\n' > "$T/.env"
stub curl 'echo "curl $*" >> "$LOG"; cat "$CFG"'; run 23:15
check "the port comes from .env" 'grep -q "^curl .*http://localhost:8080/api/config\$" "$LOG"'
rm -f "$T/.env"

# Over several checks: it switches only when the state changes, and comes back on in the morning.
stub curl 'cat "$CFG"'
config true off
stub sleep 'n=$(cat "$WORK/step" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$WORK/step"; case $n in 1) echo 23:30 > "$NOW" ;; 2) echo 23:45 > "$NOW" ;; 3) echo 06:31 > "$NOW" ;; esac'
rm -f "$WORK/step"; echo 22:00 > "$NOW"; : > "$LOG"
env PATH="$BIN:$WORK/tools" XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY=wayland-0 LOG="$LOG" CFG="$CFG" NOW="$NOW" WORK="$WORK" FAMHOMEBASE_SCREEN_MAX_TICKS=5 /bin/sh "$T/scripts/screen.sh" > "$WORK/out" 2>&1
check "over a night: on at start, off once, on once in the morning — no repeats" '[ "$(grep -c "^wlopm" "$LOG")" -eq 3 ] && [ "$(grep "^wlopm" "$LOG" | tr "\n" " ")" = "wlopm --on HDMI-A-1 wlopm --off HDMI-A-1 wlopm --on HDMI-A-1 " ]'

stub wlopm 'echo "wlopm $*" >> "$LOG"; exit 1'
stub sleep ':'
config true off; run 23:15
check "a wlopm that fails is reported and does not stop it" 'grep -q "could not turn the screen off" "$WORK/out"'

rm "$BIN/wlopm"
run 23:15; status=$?
check "without wlopm it says so and exits cleanly (dimming still works)" '[ $status -eq 0 ] && grep -q "wlopm is not installed" "$WORK/out"'

echo; echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
