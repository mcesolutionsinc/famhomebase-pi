#!/bin/sh
# Tests for scripts/kiosk.sh with stubbed chromium, curl, wlr-randr and sleep. Run: sh tests/test-kiosk.sh
# shellcheck disable=SC2034,SC2120 # `rc` is read by the checks' eval; `run` takes extra env as arguments only when a test passes some
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
T="$WORK/inst"; BIN="$WORK/bin"; RT="$WORK/run"
mkdir -p "$T" "$BIN" "$RT" "$WORK/tools" "$WORK/etc"
ENVF="$WORK/etc/famhomebase.env"
# Only the system tools the script really needs, so a chromium or wlr-randr that happens to be installed on this machine can't leak in.
for tool in sed tail awk dirname mkdir rm; do ln -s "$(command -v $tool)" "$WORK/tools/$tool"; done
cp "$HERE/../scripts/kiosk.sh" "$T/kiosk.sh"
LOG="$WORK/log"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
stub sleep ':'
stub id 'echo 1000'
stub curl 'echo "curl $*" >> "$LOG"; exit 0'
stub chromium 'echo "chromium $*" >> "$LOG"'
stub wlr-randr 'echo "wlr-randr $*" >> "$LOG"'

run() { # extra env as args; returns the script's exit status
  : > "$LOG"
  env PATH="$BIN:$WORK/tools" HOME="$WORK/home" XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY=wayland-0 LOG="$LOG" FAMHOMEBASE_ETC_DIR="$WORK/etc" FAMHOMEBASE_STATE_DIR="$WORK/state" "$@" /bin/sh "$T/kiosk.sh" > "$WORK/out" 2>&1
}
mkdir -p "$WORK/home"

rm -f "$ENVF"; run
check "defaults: port 80, no port in the address, the kiosk flag" 'grep -q "^chromium .*http://localhost/?kiosk=1\$" "$LOG" && grep -q "^curl .*http://localhost/\$" "$LOG"'
check "the browser flags: Wayland, kiosk, no dialogs, no first-run, no keyring" 'grep -q "ozone-platform=wayland" "$LOG" && grep -q -- "--kiosk" "$LOG" && grep -q "noerrdialogs" "$LOG" && grep -q "no-first-run" "$LOG" && grep -q "password-store=basic" "$LOG"'
check "a saved profile of its own, in the state folder by default, and no restore bubble" 'grep -q -- "--user-data-dir=$WORK/state/kiosk-profile" "$LOG" && grep -q -- "--hide-crash-restore-bubble" "$LOG" && [ -d "$WORK/state/kiosk-profile" ]'
check "no rotation setting: the screen is left alone" '! grep -q "^wlr-randr" "$LOG"'

printf 'FAMHOMEBASE_PORT=8080\n' > "$ENVF"; run
check "the port comes from .env (and the wait uses it too)" 'grep -q "^chromium .*http://localhost:8080/?kiosk=1\$" "$LOG" && grep -q "^curl .*http://localhost:8080/\$" "$LOG"'
printf 'FAMHOMEBASE_PORT=abc\n' > "$ENVF"; run
check "a junk port falls back to 80" 'grep -q "http://localhost/?kiosk=1" "$LOG"'
printf 'AUTO_UPDATE=true\nFAMHOMEBASE_PORT=81\nFAMHOMEBASE_PORT=8081\n' > "$ENVF"; run
check "the last setting wins when .env repeats one" 'grep -q "localhost:8081/?kiosk=1" "$LOG"'

printf 'FAMHOMEBASE_PROFILE=%s/elsewhere\n' "$WORK" > "$ENVF"; run
check "the profile folder comes from .env" 'grep -q -- "--user-data-dir=$WORK/elsewhere " "$LOG" && [ -d "$WORK/elsewhere" ]'
mkdir -p "$WORK/state/kiosk-profile"; touch "$WORK/state/kiosk-profile/SingletonLock" "$WORK/state/kiosk-profile/SingletonCookie" "$WORK/state/kiosk-profile/Keep"; rm -f "$ENVF"; run
check "stale Chromium lock files from a power cut are cleared, other profile files are kept" '[ ! -e "$WORK/state/kiosk-profile/SingletonLock" ] && [ ! -e "$WORK/state/kiosk-profile/SingletonCookie" ] && [ -e "$WORK/state/kiosk-profile/Keep" ]'
mkdir -p "$WORK/state/kiosk-profile/WidevineCdm/4.10.3112.0"; touch "$WORK/state/kiosk-profile/WidevineCdm/4.10.3112.0/manifest.json" "$WORK/state/kiosk-profile/Keep"; run
check "a Widevine component left in the profile (it makes the next start crash on a Pi) is dropped, and the rest of the profile is kept" '[ ! -e "$WORK/state/kiosk-profile/WidevineCdm" ] && [ -e "$WORK/state/kiosk-profile/Keep" ]'
check "component downloads are switched off, so it does not come back" 'grep -q -- "--disable-component-update" "$LOG"'
printf 'FAMHOMEBASE_PROFILE=relative/x\n' > "$ENVF"; run; rc=$?
check "a profile path that is not absolute is refused" '[ $rc -ne 0 ] && grep -q "must be a full path" "$WORK/out" && ! grep -q "^chromium" "$LOG"'
printf 'FAMHOMEBASE_PROFILE=/proc/nope/x\n' > "$ENVF"; run; rc=$?
check "a profile folder that cannot be made: says so, does not open the browser" '[ $rc -ne 0 ] && grep -q "cannot make the profile folder" "$WORK/out" && ! grep -q "^chromium" "$LOG"'

printf 'FAMHOMEBASE_ROTATE=90\n' > "$ENVF"; run
check "rotation is not the kiosk's job (the app turns itself): the setting is ignored, with a message that says where it is set, and the screen is not touched" '! grep -q "^wlr-randr" "$LOG" && grep -q "^chromium" "$LOG" && grep -q "FAMHOMEBASE_ROTATE is ignored since 0.4.0" "$WORK/out"'

# the browser
rm -f "$BIN/chromium"; stub chromium-browser 'echo "chromium-browser $*" >> "$LOG"'; run
check "older Raspberry Pi OS: falls back to chromium-browser" 'grep -q "^chromium-browser .*kiosk=1" "$LOG"'
rm -f "$BIN/chromium-browser"; run; rc=$?
check "no browser installed: says so" '[ $rc -ne 0 ] && grep -q "chromium is not installed" "$WORK/out"'

echo; echo "$n checks, $fail failed"
[ "$fail" -eq 0 ]
