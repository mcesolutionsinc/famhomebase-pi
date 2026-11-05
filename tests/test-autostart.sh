#!/bin/sh
# Tests for scripts/fix-autostart.sh on its own. Run: sh tests/test-autostart.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/fix-autostart.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
F="$WORK/labwc/autostart"; mkdir -p "$WORK/labwc"
OLD="sh -c 'until curl -sf http://localhost:8080/ >/dev/null; do sleep 2; done; exec chromium-browser --kiosk \"http://localhost:8080/?kiosk=1\"' &"

printf '# mine\n%s\nwlr-randr --output X --transform 90\n' "$OLD" > "$F"
out=$(sh "$SCRIPT" "$F" http://localhost)
check "a stale kiosk line is replaced, reported as changed" '[ "$out" = changed ] && grep -q "localhost/?kiosk=1" "$F" && ! grep -q 8080 "$F" && grep -q "ozone-platform=wayland" "$F"'
check "the other lines stay, in place" '[ "$(sed -n 1p "$F")" = "# mine" ] && [ "$(sed -n 3p "$F")" = "wlr-randr --output X --transform 90" ]'
check "the old file is saved as .bak" 'grep -q 8080 "$F.bak"'
out=$(sh "$SCRIPT" "$F" http://localhost)
check "run again: unchanged" '[ "$out" = unchanged ]'
out=$(sh "$SCRIPT" "$F" http://localhost:8081)
check "a different address is a change" '[ "$out" = changed ] && grep -q "localhost:8081/?kiosk=1" "$F" && [ "$(grep -c "kiosk=1" "$F")" = 1 ]'

printf 'wlr-randr --output X --transform 90\n' > "$F"; rm -f "$F.bak"
out=$(sh "$SCRIPT" "$F" http://localhost)
check "no kiosk line and no --add: absent, file untouched" '[ "$out" = absent ] && [ "$(cat "$F")" = "wlr-randr --output X --transform 90" ] && [ ! -e "$F.bak" ]'
out=$(sh "$SCRIPT" "$F" http://localhost --add)
check "--add appends the line and keeps the rest" '[ "$out" = added ] && grep -q "wlr-randr" "$F" && grep -q "localhost/?kiosk=1" "$F" && [ -e "$F.bak" ]'
rm -rf "$WORK/new"; out=$(sh "$SCRIPT" "$WORK/new/labwc/autostart" http://localhost --add)
check "--add creates a missing file (and its folder)" '[ "$out" = added ] && grep -q "kiosk=1" "$WORK/new/labwc/autostart"'
printf '%s\n%s\n' "$OLD" "$OLD" > "$F"; sh "$SCRIPT" "$F" http://localhost >/dev/null
check "two kiosk lines collapse to one" '[ "$(grep -c "kiosk=1" "$F")" = 1 ]'
out=$(sh "$SCRIPT" "$WORK/nothing" http://localhost)
check "a missing file is just absent" '[ "$out" = absent ] && [ ! -e "$WORK/nothing" ]'
sh "$SCRIPT" >/dev/null 2>&1; rc=$?
check "usage error without arguments" '[ $rc -ne 0 ]'

echo; echo "$n checks, $fail failed"
[ "$fail" -eq 0 ]
