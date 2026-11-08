#!/bin/sh
# Tests for scripts/cloud-update.sh with stubbed curl and docker and a fake host-setup (no network, no Docker, no systemd).
# Run: sh tests/test-cloud-update.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/cloud-update.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -fsSL|-fsS|-s) ;; -o) shift; out="$1" ;; *) url="$1" ;; esac; shift; done
src="$FIXTURES/${url#*://*/}"; src=${src%%\?*}
[ -f "$src" ] || exit 22
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
STUB
cat > "$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$DOCKER_LOG"
case "$1" in
  pull) [ -z "${FAIL_PULL:-}" ] ;;
  images) printf '%s\n' ${IMAGE_TAGS:-} ;;
  image) [ -z "${NO_OLD_IMAGE:-}" ] ;;
  inspect) case "$*" in
      # the image of the running container: what VERSION says, as the run script would have started it (RUNNING overrides: a restart that never happened)
      *Config.Image*) echo "ghcr.io/mcesolutionsinc/famhomebase-pi-cloud:${RUNNING:-$(cat "$INSTDIR/VERSION")}" ;;
      *) echo "${HEALTH:-healthy}" ;;
    esac ;;
esac
STUB
chmod +x "$WORK/bin/curl" "$WORK/bin/docker"
export INSTDIR="$WORK/inst" CURL="$WORK/bin/curl" DOCKER="$WORK/bin/docker" DOCKER_LOG="$WORK/docker.log" HEALTH_TIMEOUT_SECONDS=1 HEALTH_POLL_SECONDS=1
export GITHUB_API=https://api.example.test GITHUB_DOWNLOAD=https://dl.example.test

REPO=mcesolutionsinc/famhomebase-pi

# publish <version> [badsum|badpayload]: a cloud release in the fake GitHub. Its host-setup records that it ran, and fails if FAIL_HOST is set.
publish() {
  v=$1
  pay="$WORK/pay-$v"; rm -rf "$pay"; mkdir -p "$pay/scripts" "$pay/docs"
  echo "$v" > "$pay/VERSION"
  echo "release $v" > "$pay/README.md"
  echo "env example $v" > "$pay/.env.example"
  echo "run $v" > "$pay/scripts/cloud-run.sh"
  cat > "$pay/scripts/cloud-host-setup.sh" <<HS
#!/bin/sh
echo "host-setup $v \$*" >> "$WORK/host.log"
[ -z "\${FAIL_HOST:-}" ]
HS
  echo "docs $v" > "$pay/docs/INSTALL.md"
  [ "${2:-}" = badpayload ] && echo 9.9.9 > "$pay/VERSION"
  d="$FIXTURES/$REPO/releases/download/cloud-v$v"; mkdir -p "$d"
  tar -czf "$d/famhomebase-pi-cloud-$v.tar.gz" -C "$pay" .
  sum=$(sha256sum "$d/famhomebase-pi-cloud-$v.tar.gz" | cut -d' ' -f1)
  [ "${2:-}" = badsum ] && sum=0000000000000000000000000000000000000000000000000000000000000000
  echo "$sum  famhomebase-pi-cloud-$v.tar.gz" > "$d/famhomebase-pi-cloud-$v.tar.gz.sha256"
}
# list <tag>...: what the releases list says
list() { mkdir -p "$FIXTURES/repos/$REPO"; : > "$FIXTURES/repos/$REPO/releases"; for t in "$@"; do echo "  {\"tag_name\": \"$t\", \"draft\": false}," >> "$FIXTURES/repos/$REPO/releases"; done; }

# fresh <version>: an install at that version, with a .env that must survive
fresh() {
  FIXTURES="$WORK/fx"; rm -rf "$FIXTURES" "$WORK/inst" "$WORK/host.log"; mkdir -p "$FIXTURES" "$WORK/inst/scripts" "$WORK/inst/docs"
  export FIXTURES; : > "$DOCKER_LOG"; : > "$WORK/host.log"
  cp "$SCRIPT" "$WORK/inst/scripts/cloud-update.sh"
  echo "$1" > "$WORK/inst/VERSION"
  echo "old run $1" > "$WORK/inst/scripts/cloud-run.sh"
  echo "old docs $1" > "$WORK/inst/docs/INSTALL.md"
  printf '#!/bin/sh\necho "host-setup %s $*" >> "%s"\n' "$1" "$WORK/host.log" > "$WORK/inst/scripts/cloud-host-setup.sh"
  printf 'FAMHOMEBASE_ENV=staging\nAUTO_UPDATE=true\n' > "$WORK/inst/.env"
  HEALTH=healthy; export HEALTH
  unset FAIL_PULL FAIL_HOST RUNNING IMAGE_TAGS NO_OLD_IMAGE
}
update() { FAMHOMEBASE_DIR="$WORK/inst" sh "$WORK/inst/scripts/cloud-update.sh" > "$WORK/out" 2>&1; }
version() { tr -d ' \r\n' < "$WORK/inst/VERSION"; }
I="$WORK/inst"

fresh 0.1.0; publish 0.1.0; list cloud-v0.1.0; update; st=$?
check "up to date: nothing happens" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'up to date at 0.1.0' \$WORK/out && ! grep -q '^pull' \$DOCKER_LOG"

fresh 0.1.0; publish 0.1.0; publish 0.2.0; list cloud-v0.1.0 cloud-v0.2.0; update; st=$?
check "a newer release is installed: files, version and docs swapped" "[ $st = 0 ] && [ \"\$(version)\" = 0.2.0 ] && grep -q 'run 0.2.0' $I/scripts/cloud-run.sh && grep -q 'docs 0.2.0' $I/docs/INSTALL.md"
check "the image is pulled before anything changes, under the pinned name" "head -n 1 \$DOCKER_LOG | grep -q '^pull ghcr.io/mcesolutionsinc/famhomebase-pi-cloud:0.2.0'"
check "the host files are applied with --update" "grep -q 'host-setup 0.2.0 --update' \$WORK/host.log"
check ".env is kept" "grep -q 'FAMHOMEBASE_ENV=staging' $I/.env"
check "it logs JSON and says what it did" "grep -q '\"component\":\"cloud-update\"' \$WORK/out && grep -q 'updated 0.1.0 to 0.2.0' \$WORK/out"
check "nothing of the script's own copy is left in /tmp" "! ls /tmp/tmp.* 2>/dev/null | grep -q cloud-update"

fresh 0.1.0; publish 0.2.0; publish 0.10.0; publish 0.3.0; list cloud-v0.2.0 cloud-v0.10.0 cloud-v0.3.0 v1.5.0 cloud-v0.4.0-rc1; update
check "it takes the highest cloud release (0.10.0 beats 0.3.0), and ignores the old line's v* tags and a release candidate" "[ \"\$(version)\" = 0.10.0 ]"

fresh 0.1.0; publish 0.2.0; list v0.2.0 v1.0.0; update; st=$?
check "only old-line releases: nothing to do" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ]"

fresh 0.2.0; publish 0.1.0; list cloud-v0.1.0; update
check "an older release is never installed" "[ \"\$(version)\" = 0.2.0 ]"

fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; echo 'AUTO_UPDATE=false' >> "$I/.env"; update; st=$?
check "AUTO_UPDATE=false only says a release is available" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'release 0.2.0 is available' \$WORK/out"

fresh 0.1.0; update; st=$?
check "offline (no release list): a warning, exit 0, nothing changed" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'could not look up' \$WORK/out"

fresh 0.1.0; publish 0.2.0 badsum; list cloud-v0.2.0; update; st=$?
check "a bad checksum changes nothing" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'old run 0.1.0' $I/scripts/cloud-run.sh && grep -q 'checksum mismatch' \$WORK/out && ! grep -q '^pull' \$DOCKER_LOG"

fresh 0.1.0; publish 0.2.0 badpayload; list cloud-v0.2.0; update; st=$?
check "a payload whose VERSION is not the release's is refused" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'not a valid 0.2.0 release' \$WORK/out"

fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; FAIL_PULL=1 update; st=$?
check "an image that cannot be pulled changes nothing" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'old run 0.1.0' $I/scripts/cloud-run.sh && [ ! -s \$WORK/host.log ]"

fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; HEALTH=unhealthy update; st=$?
check "a display that does not become healthy: everything is put back" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'old run 0.1.0' $I/scripts/cloud-run.sh && grep -q 'old docs 0.1.0' $I/docs/INSTALL.md && grep -q 'putting the old version back' \$WORK/out"
check "the host files are applied again for the old version after the rollback" "[ \$(grep -c host-setup \$WORK/host.log) = 2 ] && tail -n 1 \$WORK/host.log | grep -q 'host-setup 0.1.0 --update'"
check "the failure is remembered, and not retried for a day" "grep -q '^0.2.0 ' $I/.update-failed"
HEALTH=healthy; update; st=$?
check "so the next check leaves it alone" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'not trying it again' \$WORK/out"
RETRY_AFTER_FAILURE_SECONDS=0 update
check "and after the wait it tries again, and succeeds" "[ \"\$(version)\" = 0.2.0 ] && [ ! -e $I/.update-failed ]"

fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; RUNNING=0.1.0 update; st=$?
check "a restart that never happened (the OLD container still running and healthy) does not count as the new version up" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'did not become healthy on 0.2.0' \$WORK/out"

fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; echo 'AUTO_UPDATE="False"' > "$I/.env"; printf 'AUTO_UPDATE=No\r\n' >> "$I/.env"; update
check "AUTO_UPDATE is read the way it is likely to be written: quotes and capitals are fine" "[ \"\$(version)\" = 0.1.0 ] && grep -q 'AUTO_UPDATE is off' \$WORK/out"
fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; printf 'AUTO_UPDATE=true\r\n' > "$I/.env"; update
check "a Windows line ending in .env does not stop an update" "[ \"\$(version)\" = 0.2.0 ]"

fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; echo "0.2.0 not-a-number" > "$I/.update-failed"; update; st=$?
check "a half-written failure record is ignored, not fatal" "[ $st = 0 ] && [ \"\$(version)\" = 0.2.0 ]"

fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; IMAGE_TAGS="0.0.9 0.1.0 0.2.0 latest" update
check "after an update the image before the previous one is removed, and this one, the previous one and other tags stay" "grep -q '^rmi ghcr.io/mcesolutionsinc/famhomebase-pi-cloud:0.0.9' \$DOCKER_LOG && ! grep -q 'rmi .*:0.1.0' \$DOCKER_LOG && ! grep -q 'rmi .*:0.2.0' \$DOCKER_LOG && ! grep -q 'rmi .*:latest' \$DOCKER_LOG"
fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; HEALTH=unhealthy NO_OLD_IMAGE=1 update
check "a rollback fetches the old image again if it is no longer on the machine" "grep -q '^pull ghcr.io/mcesolutionsinc/famhomebase-pi-cloud:0.1.0' \$DOCKER_LOG"
fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; HEALTH=unhealthy update
check "and does not when it is still there" "[ \$(grep -c '^pull ' \$DOCKER_LOG) = 1 ]"

fresh 0.1.0; publish 0.2.0; list cloud-v0.2.0; FAIL_HOST=1 update; st=$?
check "applying the new files failing puts the old version back" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'old run 0.1.0' $I/scripts/cloud-run.sh"

fresh 0.1.0; echo 'latest' > "$I/VERSION"; update; st=$?
check "a damaged VERSION stops it" "[ $st != 0 ] && grep -q 'not a version' \$WORK/out"
fresh 0.1.0; FAMHOMEBASE_DIR=/ sh "$I/scripts/cloud-update.sh" > "$WORK/out" 2>&1; st=$?
check "it refuses the filesystem root as the install folder" "[ $st != 0 ]"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
