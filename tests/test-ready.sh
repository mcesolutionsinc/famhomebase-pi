#!/bin/sh
# Tests for scripts/ready.sh with a stubbed curl and sleep. Run: sh tests/test-ready.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/ready.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/etc"
# curl succeeds from the Nth call on (UP_AFTER, default 1), and logs the address it asked for
printf '#!/bin/sh\necho "$*" >> "$WORK/curl.log"\nc=$(wc -l < "$WORK/curl.log")\n[ "$c" -ge "${UP_AFTER:-1}" ]\n' > "$WORK/curl"
printf '#!/bin/sh\necho s >> "$WORK/sleep.log"\n' > "$WORK/sleep"
chmod +x "$WORK/curl" "$WORK/sleep"
export WORK CURL="$WORK/curl" SLEEP="$WORK/sleep" FAMHOMEBASE_ETC_DIR="$WORK/etc"
run() { : > "$WORK/curl.log"; : > "$WORK/sleep.log"; sh "$SCRIPT" > "$WORK/out" 2>&1; }

: > "$WORK/etc/famhomebase.env"; UP_AFTER=1 run; st=$?
check "a page that is already served: no waiting, exit 0, a JSON line, and it asks the loopback address on port 80" "[ $st = 0 ] && [ ! -s $WORK/sleep.log ] && grep -q 'http://127.0.0.1:80/' $WORK/curl.log && grep -q '\"component\":\"ready\"' $WORK/out"
UP_AFTER=4 run; st=$?
check "a page that comes up after 3 tries: it waits a second between tries and then goes on" "[ $st = 0 ] && [ \$(wc -l < $WORK/sleep.log) = 3 ] && grep -q 'after 3s' $WORK/out"
printf 'FAMHOMEBASE_PORT=8080\n' > "$WORK/etc/famhomebase.env"; UP_AFTER=1 run
check "the port comes from the settings file" "grep -q 'http://127.0.0.1:8080/' $WORK/curl.log"
printf 'FAMHOMEBASE_PORT=abc\n' > "$WORK/etc/famhomebase.env"; UP_AFTER=1 run
check "a junk port falls back to 80" "grep -q 'http://127.0.0.1:80/' $WORK/curl.log"
: > "$WORK/etc/famhomebase.env"; UP_AFTER=100 FAMHOMEBASE_READY_SECONDS=5 run; st=$?
check "a page that never comes up: it gives up after the limit with a warning, and still exits 0 (boot must go on)" "[ $st = 0 ] && [ \$(wc -l < $WORK/sleep.log) = 5 ] && grep -q '\"level\":\"warn\"' $WORK/out"
UP_AFTER=100 FAMHOMEBASE_READY_SECONDS=abc run; st=$?
check "a junk limit falls back to 90" "[ $st = 0 ] && [ \$(wc -l < $WORK/sleep.log) = 90 ]"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
