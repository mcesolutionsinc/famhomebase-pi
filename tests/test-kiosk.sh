#!/bin/sh
# Tests for scripts/kiosk.sh with stubbed chromium, curl, wlr-randr and sleep. Run: sh tests/test-kiosk.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
T="$WORK/inst"; BIN="$WORK/bin"; RT="$WORK/run"
mkdir -p "$T/scripts" "$BIN" "$RT" "$WORK/tools"
# Only the system tools the script really needs, so a chromium or wlr-randr that happens to be installed on this machine can't leak in.
for tool in sed tail awk dirname mkdir; do ln -s "$(command -v $tool)" "$WORK/tools/$tool"; done
cp "$HERE/../scripts/kiosk.sh" "$T/scripts/kiosk.sh"
LOG="$WORK/log"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
stub sleep ':'
stub id 'echo 1000'
stub curl 'echo "curl $*" >> "$LOG"; exit 0'
stub chromium 'echo "chromium $*" >> "$LOG"'
stub wlr-randr 'if [ $# -eq 0 ]; then echo "HDMI-A-1 \"Some Monitor\""; echo "  Modes:"; echo "DSI-1 \"Touch\""; else echo "wlr-randr $*" >> "$LOG"; fi'

run() { # extra env as args; returns the script's exit status
  : > "$LOG"
  env PATH="$BIN:$WORK/tools" HOME="$WORK/home" XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY=wayland-0 LOG="$LOG" "$@" /bin/sh "$T/scripts/kiosk.sh" > "$WORK/out" 2>&1
}
touch "$RT/wayland-0" # the desktop is up
mkdir -p "$WORK/home"

rm -f "$T/.env"; run
check "defaults: port 80, no port in the address, the kiosk flag" 'grep -q "^chromium .*http://localhost/?kiosk=1\$" "$LOG" && grep -q "^curl .*http://localhost/\$" "$LOG"'
check "the browser flags: Wayland, kiosk, no dialogs, no first-run, no keyring" 'grep -q "ozone-platform=wayland" "$LOG" && grep -q -- "--kiosk" "$LOG" && grep -q "noerrdialogs" "$LOG" && grep -q "no-first-run" "$LOG" && grep -q "password-store=basic" "$LOG"'
check "a saved profile of its own, under the home folder by default, and no restore bubble" 'grep -q -- "--user-data-dir=$WORK/home/.local/share/famhomebase-kiosk" "$LOG" && grep -q -- "--hide-crash-restore-bubble" "$LOG" && [ -d "$WORK/home/.local/share/famhomebase-kiosk" ]'
check "no rotation setting: the screen is left alone" '! grep -q "^wlr-randr" "$LOG"'

printf 'FAMHOMEBASE_PORT=8080\n' > "$T/.env"; run
check "the port comes from .env (and the wait uses it too)" 'grep -q "^chromium .*http://localhost:8080/?kiosk=1\$" "$LOG" && grep -q "^curl .*http://localhost:8080/\$" "$LOG"'
printf 'FAMHOMEBASE_PORT=abc\n' > "$T/.env"; run
check "a junk port falls back to 80" 'grep -q "http://localhost/?kiosk=1" "$LOG"'
printf 'AUTO_UPDATE=true\nFAMHOMEBASE_PORT=81\nFAMHOMEBASE_PORT=8081\n' > "$T/.env"; run
check "the last setting wins when .env repeats one" 'grep -q "localhost:8081/?kiosk=1" "$LOG"'

printf 'FAMHOMEBASE_PROFILE=%s/elsewhere\n' "$WORK" > "$T/.env"; run
check "the profile folder comes from .env" 'grep -q -- "--user-data-dir=$WORK/elsewhere " "$LOG" && [ -d "$WORK/elsewhere" ]'
printf 'FAMHOMEBASE_PROFILE=/proc/nope/x\n' > "$T/.env"; run; rc=$?
check "a profile folder that cannot be made: says so, does not open the browser" '[ $rc -ne 0 ] && grep -q "cannot make the profile folder" "$WORK/out" && ! grep -q "^chromium" "$LOG"'

printf 'FAMHOMEBASE_ROTATE=90\n' > "$T/.env"; run
check "rotation: the first display wlr-randr lists is rotated" 'grep -q "^wlr-randr --output HDMI-A-1 --transform 90\$" "$LOG"'
check "rotation happens before the browser opens" '[ "$(grep -n "^wlr-randr" "$LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n "^chromium" "$LOG" | head -1 | cut -d: -f1)" ]'
printf 'FAMHOMEBASE_ROTATE=270\nFAMHOMEBASE_OUTPUT=DSI-1\n' > "$T/.env"; run
check "rotation: FAMHOMEBASE_OUTPUT picks the display" 'grep -q "^wlr-randr --output DSI-1 --transform 270\$" "$LOG"'
printf 'FAMHOMEBASE_ROTATE=normal\n' > "$T/.env"; run
check "rotation: normal is a valid value (puts it back)" 'grep -q "^wlr-randr --output HDMI-A-1 --transform normal\$" "$LOG"'
printf 'FAMHOMEBASE_ROTATE=45\n' > "$T/.env"; run
check "rotation: an invalid value is ignored, with a message, and the display still opens" '! grep -q "^wlr-randr" "$LOG" && grep -q "ignoring FAMHOMEBASE_ROTATE" "$WORK/out" && grep -q "^chromium" "$LOG"'
printf 'FAMHOMEBASE_ROTATE=90\n' > "$T/.env"; rm -f "$BIN/wlr-randr"; run
check "rotation: no wlr-randr installed says so, and the display still opens" 'grep -q "wlr-randr is not installed" "$WORK/out" && grep -q "^chromium" "$LOG"'
stub wlr-randr 'echo none >/dev/null'; run
check "rotation: no display found says so, and the display still opens" 'grep -q "no display was found" "$WORK/out" && grep -q "^chromium" "$LOG"'
stub wlr-randr 'if [ $# -eq 0 ]; then echo "HDMI-A-1 x"; else exit 1; fi'; run
check "rotation: a failed rotate is reported but does not stop the display" 'grep -q "could not rotate HDMI-A-1" "$WORK/out" && grep -q "^chromium" "$LOG"'

# waiting for the desktop
rm -f "$RT/wayland-0" "$T/.env"; run; rc=$?
check "no desktop session: gives up after a while with a clear message, so systemd can retry" '[ $rc -ne 0 ] && grep -q "no desktop session found" "$WORK/out" && ! grep -q "^chromium" "$LOG"'
touch "$RT/wayland-0"

# the browser
rm -f "$BIN/chromium"; stub chromium-browser 'echo "chromium-browser $*" >> "$LOG"'; run
check "older Raspberry Pi OS: falls back to chromium-browser" 'grep -q "^chromium-browser .*kiosk=1" "$LOG"'
rm -f "$BIN/chromium-browser"; run; rc=$?
check "no browser installed: says so" '[ $rc -ne 0 ] && grep -q "chromium is not installed" "$WORK/out"'

echo; echo "$n checks, $fail failed"
[ "$fail" -eq 0 ]
