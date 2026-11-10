#!/bin/sh
# Tests for scripts/load-image.sh with a stubbed docker. Run: sh tests/test-load-image.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/load-image.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/state"
printf '#!/bin/sh\necho "docker $*" >> "$WORK/docker.log"\n[ -z "${FAIL_LOAD:-}" ]\n' > "$WORK/docker"; chmod +x "$WORK/docker"
export FAMHOMEBASE_LOAD_RETRY_SLEEP=0 WORK DOCKER="$WORK/docker" FAMHOMEBASE_STATE_DIR="$WORK/state"
run() { : > "$WORK/docker.log"; sh "$SCRIPT" > "$WORK/out" 2>&1; }

run; st=$?
check "no saved image: does nothing, exits 0, never calls docker" "[ $st = 0 ] && [ ! -s $WORK/docker.log ] && [ ! -s $WORK/out ]"
echo x > "$WORK/state/image.tar.gz"; run; st=$?
check "a saved image: loaded with docker load, then deleted, exit 0" "[ $st = 0 ] && grep -q \"^docker load -i $WORK/state/image.tar.gz\$\" $WORK/docker.log && [ ! -e $WORK/state/image.tar.gz ] && grep -q 'loaded' $WORK/out"
echo x > "$WORK/state/image.tar.gz"; FAIL_LOAD=1 run; st=$?
check "a saved image that will not load: a warning that says what happens next, the file is deleted anyway, exit 0 (boot must go on)" "[ $st = 0 ] && grep -q '\"level\":\"warn\"' $WORK/out && grep -q 'downloaded instead' $WORK/out && [ ! -e $WORK/state/image.tar.gz ]"
echo x > "$WORK/state/image.tar.gz"; run
check "its log lines are JSON" "grep -q '^{\"ts\":\".*\",\"level\":\"info\",\"component\":\"load-image\"' $WORK/out"

printf '#!/bin/sh\necho "docker $*" >> "$WORK/docker.log"\nc=$(cat "$WORK/count" 2>/dev/null || echo 0); c=$((c+1)); echo $c > "$WORK/count"\n[ "$c" -ge 3 ]\n' > "$WORK/docker-flaky"; chmod +x "$WORK/docker-flaky"
rm -f "$WORK/count"; echo x > "$WORK/state/image.tar.gz"; DOCKER="$WORK/docker-flaky" run; st=$?
check "a load that fails twice and then works is retried, reported as loaded, and the file is deleted" "[ $st = 0 ] && [ \"\$(grep -c '^docker load' $WORK/docker.log)\" = 3 ] && grep -q '\"msg\":\"loaded\"' $WORK/out && [ ! -e $WORK/state/image.tar.gz ]"
echo x > "$WORK/state/image.tar.gz"; FAIL_LOAD=1 run
check "a load that always fails is tried three times, then the download fallback is announced" "[ \"\$(grep -c '^docker load' $WORK/docker.log)\" = 3 ] && grep -q 'try 3 of 3' $WORK/out && grep -q 'downloaded instead' $WORK/out"
echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
