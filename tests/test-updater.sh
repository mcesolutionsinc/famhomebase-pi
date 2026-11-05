#!/bin/sh
# Tests for updater/update.sh with stubbed wget and docker (no network, no Docker needed). Run: sh tests/test-updater.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../updater/update.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/wget" <<'STUB'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -qO-) out="-";; -q) ;; -O) shift; out="$1";; *) url="$1";; esac; shift; done
src="$FIXTURES/${url#*://*/}"
[ -f "$src" ] || exit 1
if [ "$out" = "-" ]; then cat "$src"; else cp "$src" "$out"; fi
STUB
cat > "$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  "compose pull") [ -z "${FAIL_PULL:-}" ] ;;
  "compose up") exit 0 ;;
  "compose ps") echo "id-$4" ;;
  "inspect -f") case "$4" in id-*) echo "${HEALTH:-healthy}" ;; *) echo "docker:27-cli" ;; esac ;;
  "run -d") echo helper ;;
esac
STUB
chmod +x "$WORK/bin/wget" "$WORK/bin/docker"

REPO=mcesolutionsinc/famhomebase-pi

# publish <version> [badsum]: a release in the fake GitHub
publish() {
  v=$1
  pay="$WORK/pay-$v"; rm -rf "$pay"; mkdir -p "$pay/scripts" "$pay/updater" "$pay/docs"
  echo "services: {app: {image: 'app:$v'}}" > "$pay/docker-compose.yml"
  echo "$v" > "$pay/VERSION"
  echo "release $v" > "$pay/README.md"
  echo "gen $v" > "$pay/scripts/generate-key.sh"
  echo "updater $v" > "$pay/updater/update.sh"
  echo "docs $v" > "$pay/docs/INSTALL.md"
  d="$FIXTURES/$REPO/releases/download/v$v"; mkdir -p "$d"
  tar -czf "$d/famhomebase-pi-$v.tar.gz" -C "$pay" .
  sum=$(sha256sum "$d/famhomebase-pi-$v.tar.gz" | cut -d' ' -f1)
  [ "${2:-}" = badsum ] && sum=0000000000000000000000000000000000000000000000000000000000000000
  echo "$sum  famhomebase-pi-$v.tar.gz" > "$d/famhomebase-pi-$v.tar.gz.sha256"
  mkdir -p "$FIXTURES/repos/$REPO/releases"
  echo "{\"tag_name\": \"v$v\", \"draft\": false}" > "$FIXTURES/repos/$REPO/releases/latest"
}

# install_dir <version>: a release install at that version, with data that must survive
fresh() {
  FIXTURES="$WORK/fx"; rm -rf "$FIXTURES" "$WORK/inst"; mkdir -p "$FIXTURES" "$WORK/inst/data" "$WORK/inst/secrets" "$WORK/inst/scripts" "$WORK/inst/updater" "$WORK/inst/docs"
  export FIXTURES
  echo "services: {app: {image: 'app:$1'}}" > "$WORK/inst/docker-compose.yml"
  echo "$1" > "$WORK/inst/VERSION"
  echo "old script" > "$WORK/inst/scripts/generate-key.sh"
  echo "KEEP-ME" > "$WORK/inst/data/config.json"
  echo "KEEP-KEY" > "$WORK/inst/secrets/dashboard.key"
  printf 'AUTO_UPDATE=true\nFAMHOMEBASE_DIR=%s\n' "$WORK/inst" > "$WORK/inst/.env"
  : > "$WORK/docker.log"
}

run() { # runs the updater once with the stubs; extra env via "$@" (VAR=value ...)
  env PATH="$WORK/bin:$PATH" FIXTURES="$FIXTURES" DOCKER_LOG="$WORK/docker.log" FAMHOMEBASE_DIR="$WORK/inst" \
    GITHUB_API=https://api.github.com GITHUB_DOWNLOAD=https://github.com HEALTH_TIMEOUT_SECONDS=2 HEALTH_POLL_SECONDS=1 \
    "$@" sh "$SCRIPT" --once > "$WORK/out.log" 2>&1
}

# ---- version comparison (source the function by running the script's own logic)
ver_gt() { a=$1; b=$2; sh -c ". /dev/null; $(sed -n '/^ver_gt()/,/^}/p' "$SCRIPT"); ver_gt $a $b"; }
check "0.1.5 > 0.1.4"   'ver_gt 0.1.5 0.1.4'
check "0.2.0 > 0.1.9"   'ver_gt 0.2.0 0.1.9'
check "1.0.0 > 0.9.9"   'ver_gt 1.0.0 0.9.9'
check "0.1.10 > 0.1.9 (numeric, not text)" 'ver_gt 0.1.10 0.1.9'
check "0.1.4 is not > 0.1.4" '! ver_gt 0.1.4 0.1.4'
check "0.1.3 is not > 0.1.4" '! ver_gt 0.1.3 0.1.4'

# ---- already up to date
fresh 0.1.4; publish 0.1.4; run; 
check "up to date: says so and changes nothing" 'grep -q "up to date (0.1.4)" "$WORK/out.log" && [ ! -s "$WORK/docker.log" ]'

# ---- newer release gets installed
fresh 0.1.4; publish 0.1.5; run
check "update: VERSION is now 0.1.5"            '[ "$(cat "$WORK/inst/VERSION")" = 0.1.5 ]'
check "update: compose, scripts, docs replaced" 'grep -q "app:0.1.5" "$WORK/inst/docker-compose.yml" && grep -q "gen 0.1.5" "$WORK/inst/scripts/generate-key.sh" && grep -q "docs 0.1.5" "$WORK/inst/docs/INSTALL.md"'
check "update: data, secrets and .env untouched" '[ "$(cat "$WORK/inst/data/config.json")" = KEEP-ME ] && [ "$(cat "$WORK/inst/secrets/dashboard.key")" = KEEP-KEY ] && grep -q "AUTO_UPDATE=true" "$WORK/inst/.env"'
check "update: pulled then restarted app and configstore" 'grep -q "^compose pull app configstore" "$WORK/docker.log" && grep -q "^compose up -d app configstore" "$WORK/docker.log"'
check "update: hands recreating itself to a helper container" 'grep -q "^run -d --rm" "$WORK/docker.log"'
check "update: records the update, no failure marker" '[ -f "$WORK/inst/.last-update" ] && [ ! -f "$WORK/inst/.update-failed" ]'

# ---- a release that does not come up healthy is rolled back
fresh 0.1.4; publish 0.1.5; run HEALTH=unhealthy
check "rollback: previous files restored"  '[ "$(cat "$WORK/inst/VERSION")" = 0.1.4 ] && grep -q "app:0.1.4" "$WORK/inst/docker-compose.yml" && grep -q "old script" "$WORK/inst/scripts/generate-key.sh"'
check "rollback: data untouched"           '[ "$(cat "$WORK/inst/data/config.json")" = KEEP-ME ]'
check "rollback: restarted on the old files, and no self-recreate helper" '[ "$(grep -c "^compose up -d app configstore" "$WORK/docker.log")" = 2 ] && ! grep -q "^run -d" "$WORK/docker.log"'
check "rollback: remembers the failed version" 'grep -q "^0.1.5 " "$WORK/inst/.update-failed"'
: > "$WORK/docker.log"; run
check "rollback: does not retry the same bad version straight away" 'grep -q "failed to start recently" "$WORK/out.log" && [ ! -s "$WORK/docker.log" ]'
check "rollback: ...but tries again after the cool-off" 'run RETRY_AFTER_FAILURE_SECONDS=0 && grep -q "^compose pull" "$WORK/docker.log"'

# ---- a failed pull leaves everything as it was
fresh 0.1.4; publish 0.1.5; run FAIL_PULL=1
check "pull failure: old files put back, nothing restarted" '[ "$(cat "$WORK/inst/VERSION")" = 0.1.4 ] && ! grep -q "^compose up" "$WORK/docker.log"'

# ---- integrity and sanity
fresh 0.1.4; publish 0.1.5 badsum; run
check "bad checksum: refuses to install" 'grep -q "checksum mismatch" "$WORK/out.log" && [ "$(cat "$WORK/inst/VERSION")" = 0.1.4 ] && [ ! -s "$WORK/docker.log" ]'
fresh 0.1.4; publish 0.1.5; echo 9.9.9 > "$WORK/pay-0.1.5/VERSION"; tar -czf "$FIXTURES/$REPO/releases/download/v0.1.5/famhomebase-pi-0.1.5.tar.gz" -C "$WORK/pay-0.1.5" .
( cd "$FIXTURES/$REPO/releases/download/v0.1.5" && echo "$(sha256sum famhomebase-pi-0.1.5.tar.gz | cut -d' ' -f1)  famhomebase-pi-0.1.5.tar.gz" > famhomebase-pi-0.1.5.tar.gz.sha256 ); run
check "payload whose VERSION does not match its release: refused" 'grep -q "not a valid 0.1.5 release" "$WORK/out.log" && [ "$(cat "$WORK/inst/VERSION")" = 0.1.4 ]'

# ---- opt-out, dev checkouts, offline, odd tags
fresh 0.1.4; publish 0.1.5; run AUTO_UPDATE=false
check "auto-update off: only says it is available" 'grep -q "auto-update is off" "$WORK/out.log" && [ "$(cat "$WORK/inst/.update-available")" = 0.1.5 ] && [ "$(cat "$WORK/inst/VERSION")" = 0.1.4 ] && [ ! -s "$WORK/docker.log" ]'
fresh dev; publish 0.1.5; run
check "development checkout (VERSION=dev): never updates" 'grep -q "development checkout" "$WORK/out.log" && [ ! -s "$WORK/docker.log" ]'
fresh 0.1.4; run
check "offline / no release found: carries on quietly" 'grep -q "could not read the latest release" "$WORK/out.log" && [ ! -s "$WORK/docker.log" ]'
fresh 0.1.4; publish 0.1.5; echo '{"tag_name": "nightly"}' > "$FIXTURES/repos/$REPO/releases/latest"; run
check "a tag that is not vX.Y.Z is ignored" 'grep -q "could not read the latest release" "$WORK/out.log" && [ "$(cat "$WORK/inst/VERSION")" = 0.1.4 ]'
fresh 0.1.5; publish 0.1.4; run
check "never downgrades" 'grep -q "up to date" "$WORK/out.log" && [ "$(cat "$WORK/inst/VERSION")" = 0.1.5 ]'

echo; echo "$n checks, $fail failed"
[ "$fail" -eq 0 ]
