#!/bin/sh
# Tests for scripts/run.sh with a stubbed docker (no Docker needed). Run: sh tests/test-run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/run.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$DOCKER_LOG"
STUB
chmod +x "$WORK/docker"
export DOCKER="$WORK/docker" DOCKER_LOG="$WORK/docker.log"

# an install: the script and its VERSION in one folder (as in /usr/local/lib/famhomebase), the settings file in another (/etc/famhomebase)
export FAMHOMEBASE_ETC_DIR="$WORK/etc" FAMHOMEBASE_STATE_DIR="$WORK/state"
ENVF="$WORK/etc/famhomebase.env"
fresh() { rm -rf "${WORK:?}/inst" "${WORK:?}/etc"; mkdir -p "$WORK/inst" "$WORK/etc"; cp "$SCRIPT" "$WORK/inst/"; : > "$DOCKER_LOG"; [ -n "${1:-}" ] && echo "$1" > "$WORK/inst/VERSION"; : > "$ENVF"; }
run() { sh "$WORK/inst/run.sh" > "$WORK/out" 2> "$WORK/err"; }

fresh 0.1.0; run; st=$?
check "starts with defaults: prod, port 80 on the loopback only, the production site" "[ $st = 0 ] && grep -q 'run --rm --name famhomebase-display -p 127.0.0.1:80:8080' \$DOCKER_LOG && grep -q 'FAMHOMEBASE_ENV=prod' \$DOCKER_LOG && grep -q 'FAMHOMEBASE_API_URL=https://famhomebase.mc-esolutions.ca' \$DOCKER_LOG"
check "the state folder is shared with the container (as /state), made if it is not there" "grep -q -- \"-v $WORK/state/state:/state\" \$DOCKER_LOG && [ -d $WORK/state/state ]"
check "the image is the pinned version, from GHCR" "grep -q 'ghcr.io/mcesolutionsinc/famhomebase-pi:0.1.0\$' \$DOCKER_LOG"
check "it removes a leftover container of the same name first" "head -n 1 \$DOCKER_LOG | grep -q '^rm -f famhomebase-display'"
check "it carries a health check on the page's own server" "grep -q -- '--health-cmd wget -qO- http://127.0.0.1:8080/runtime-config.json' \$DOCKER_LOG"
check "its log line is JSON" "grep -q '^{\"ts\":\".*\"level\":\"info\",\"component\":\"run\"' \$WORK/out"

fresh 0.2.3; printf 'FAMHOMEBASE_ENV=staging\nFAMHOMEBASE_API_URL=https://staging.example.net\nFAMHOMEBASE_PORT=8080\nFAMHOMEBASE_IMAGE=local/img\n' > "$ENVF"; run; st=$?
check "reads the settings file: staging, address, port and image" "[ $st = 0 ] && grep -q -- '-p 127.0.0.1:8080:8080' \$DOCKER_LOG && grep -q 'FAMHOMEBASE_ENV=staging' \$DOCKER_LOG && grep -q 'FAMHOMEBASE_API_URL=https://staging.example.net' \$DOCKER_LOG && grep -q 'local/img:0.2.3\$' \$DOCKER_LOG"

fresh 0.1.0; printf 'FAMHOMEBASE_PORT=8080\r\nFAMHOMEBASE_ENV="staging"\r\nFAMHOMEBASE_API_URL=%s\r\n' "'https://staging.example.net'" > "$ENVF"; run; st=$?
check "a .env written on Windows or with quotes is read as meant" "[ $st = 0 ] && grep -q -- '-p 127.0.0.1:8080:8080' \$DOCKER_LOG && grep -q 'FAMHOMEBASE_ENV=staging ' \$DOCKER_LOG && grep -q 'FAMHOMEBASE_API_URL=https://staging.example.net ' \$DOCKER_LOG"

fresh 0.1.0; printf 'FAMHOMEBASE_BIND=0.0.0.0\n' > "$ENVF"; run; st=$?
check "FAMHOMEBASE_BIND opens it to the network (only for looking at it from another computer while testing)" "[ $st = 0 ] && grep -q -- '-p 0.0.0.0:80:8080' \$DOCKER_LOG"
fresh 0.1.0; echo 'FAMHOMEBASE_BIND=localhost; rm -rf /' > "$ENVF"; run; st=$?
check "a bind address that is not an IPv4 address stops it with a JSON error and starts nothing" "[ $st != 0 ] && grep -q 'not an IPv4 address' \$WORK/out && ! grep -q '^run ' \$DOCKER_LOG"
fresh 0.1.0; echo 'FAMHOMEBASE_BIND=999.1.1.1' > "$ENVF"; run; st=$?
check "an address with a number over 255 is refused too" "[ $st != 0 ] && grep -q 'not an IPv4 address' \$WORK/out && ! grep -q '^run ' \$DOCKER_LOG"
fresh 0.1.0; echo 'FAMHOMEBASE_PORT=99999' > "$ENVF"; run; st=$?
check "a bad port stops it with a JSON error and starts nothing" "[ $st != 0 ] && grep -q '\"level\":\"error\"' \$WORK/out && ! grep -q '^run ' \$DOCKER_LOG"
fresh 0.1.0; echo 'FAMHOMEBASE_ENV=dev' > "$ENVF"; run; st=$?
check "an unknown environment stops it" "[ $st != 0 ] && grep -q 'prod or staging' \$WORK/out"
fresh 'latest'; run; st=$?
check "a VERSION that is not x.y.z stops it" "[ $st != 0 ] && ! grep -q '^run ' \$DOCKER_LOG"
fresh; rm -f "$WORK/inst/VERSION"; run; st=$?
check "a missing VERSION stops it" "[ $st != 0 ]"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
