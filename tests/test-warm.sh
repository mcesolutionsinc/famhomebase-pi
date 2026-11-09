#!/bin/sh
# Tests for scripts/warm.sh on scratch folders. Run: sh tests/test-warm.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/warm.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/chromium/sub" "$WORK/dri"
echo a > "$WORK/chromium/chromium"; echo b > "$WORK/chromium/sub/resources.pak"; echo c > "$WORK/cage"; echo d > "$WORK/dri/vc4_dri.so"
printf 'MemTotal: 1888000 kB\nMemAvailable: 1200000 kB\n' > "$WORK/meminfo.big"
printf 'MemTotal: 400000 kB\nMemAvailable: 300000 kB\n' > "$WORK/meminfo.small"
run() { FAMHOMEBASE_MEMINFO="$1" FAMHOMEBASE_WARM_DIRS="$WORK/chromium $WORK/not-there" FAMHOMEBASE_WARM_CAGE="$WORK/cage" FAMHOMEBASE_WARM_DRI="$WORK/dri/vc4_dri.so $WORK/dri/missing.so" sh "$SCRIPT" > "$WORK/out" 2>&1; }

run "$WORK/meminfo.big"; st=$?
check "with enough memory: exits 0 and reports what it read (the browser folder, cage and one driver; the missing ones are skipped)" "[ $st = 0 ] && grep -q 'read 3 browser and graphics locations' $WORK/out"
check "its log line is JSON" "grep -q '^{\"ts\":\".*\",\"level\":\"info\",\"component\":\"warm\"' $WORK/out"
run "$WORK/meminfo.small"; st=$?
check "short of memory: reads nothing, says so, exits 0 (a boot must never wait for or fail on this)" "[ $st = 0 ] && grep -q 'not enough free memory' $WORK/out && ! grep -q 'read ' $WORK/out"
FAMHOMEBASE_WARM_SKIP_MB=100 run "$WORK/meminfo.small"
check "the memory limit can be changed" "grep -q 'read 3 ' $WORK/out"
FAMHOMEBASE_WARM_SKIP_MB=abc run "$WORK/meminfo.small"
check "a junk limit falls back to 700" "grep -q 'not enough free memory' $WORK/out"
run "$WORK/missing-meminfo"; st=$?
check "no memory figures at all: treated as no memory to spare, still exits 0" "[ $st = 0 ] && grep -q 'not enough free memory' $WORK/out"
FAMHOMEBASE_MEMINFO="$WORK/meminfo.big" FAMHOMEBASE_WARM_DIRS="$WORK/nope" FAMHOMEBASE_WARM_CAGE="$WORK/nope" FAMHOMEBASE_WARM_DRI="$WORK/nope" sh "$SCRIPT" > "$WORK/out" 2>&1; st=$?
check "nothing installed (no browser): exits 0 and reads 0 locations" "[ $st = 0 ] && grep -q 'read 0 ' $WORK/out"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
