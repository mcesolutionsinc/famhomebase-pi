#!/bin/sh
# Tests for scripts/update.sh with stubbed curl and docker and a fake host-setup (no network, no Docker, no systemd).
# Run: sh tests/test-update.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/update.sh"
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
      *Config.Image*) echo "ghcr.io/mcesolutionsinc/famhomebase-pi:${RUNNING:-$(cat "$INSTDIR/VERSION")}" ;;
      *) echo "${HEALTH:-healthy}" ;;
    esac ;;
esac
STUB
chmod +x "$WORK/bin/curl" "$WORK/bin/docker"
export WORK
# the install, as the update script sees it: the scripts and VERSION in one folder, docs in another, the settings in a third, state in a fourth
export FAMHOMEBASE_LIB_DIR="$WORK/lib" FAMHOMEBASE_DOC_DIR="$WORK/doc" FAMHOMEBASE_ETC_DIR="$WORK/etc" FAMHOMEBASE_STATE_DIR="$WORK/state"
export INSTDIR="$WORK/lib" CURL="$WORK/bin/curl" DOCKER="$WORK/bin/docker" DOCKER_LOG="$WORK/docker.log" HEALTH_TIMEOUT_SECONDS=1 HEALTH_POLL_SECONDS=1
export GITHUB_API=https://api.example.test GITHUB_DOWNLOAD=https://dl.example.test

REPO=mcesolutionsinc/famhomebase-pi

# publish <version> [badsum|badpayload]: a release in the fake GitHub. Its host-setup records that it ran, and fails if FAIL_HOST is set.
publish() {
  v=$1
  pay="$WORK/pay-$v"; rm -rf "$pay"; mkdir -p "$pay/scripts" "$pay/doc"
  echo "$v" > "$pay/VERSION"
  echo "release $v" > "$pay/doc/README.md"
  echo "env example $v" > "$pay/famhomebase.env.example"
  echo "run $v" > "$pay/scripts/run.sh"
  cat > "$pay/scripts/host-setup.sh" <<HS
#!/bin/sh
echo "host-setup $v \$*" >> "$WORK/host.log"
[ -z "\${FAIL_HOST:-}" ]
HS
  echo "docs $v" > "$pay/doc/INSTALL.md"
  [ "${2:-}" = badpayload ] && echo 9.9.9 > "$pay/VERSION"
  d="$FIXTURES/$REPO/releases/download/v$v"; mkdir -p "$d"
  tar -czf "$d/famhomebase-pi-$v.tar.gz" -C "$pay" .
  sum=$(sha256sum "$d/famhomebase-pi-$v.tar.gz" | cut -d' ' -f1)
  [ "${2:-}" = badsum ] && sum=0000000000000000000000000000000000000000000000000000000000000000
  echo "$sum  famhomebase-pi-$v.tar.gz" > "$d/famhomebase-pi-$v.tar.gz.sha256"
}
# list <tag>...: what the releases list says
list() { mkdir -p "$FIXTURES/repos/$REPO"; : > "$FIXTURES/repos/$REPO/releases"; for t in "$@"; do echo "  {\"tag_name\": \"$t\", \"draft\": false}," >> "$FIXTURES/repos/$REPO/releases"; done; }

# fresh <version>: an install at that version, with a settings file that must survive
fresh() {
  FIXTURES="$WORK/fx"; rm -rf "$FIXTURES" "${WORK:?}/lib" "${WORK:?}/doc" "${WORK:?}/etc" "${WORK:?}/state" "$WORK/host.log"; mkdir -p "$FIXTURES" "$WORK/lib" "$WORK/doc" "$WORK/etc" "$WORK/state"
  export FIXTURES; : > "$DOCKER_LOG"; : > "$WORK/host.log"
  cp "$SCRIPT" "$WORK/lib/update.sh"
  echo "$1" > "$WORK/lib/VERSION"
  echo "old run $1" > "$WORK/lib/run.sh"
  echo "old docs $1" > "$WORK/doc/INSTALL.md"
  echo "old example $1" > "$WORK/etc/famhomebase.env.example"
  printf '#!/bin/sh\necho "host-setup %s $*" >> "%s"\n' "$1" "$WORK/host.log" > "$WORK/lib/host-setup.sh"
  printf 'FAMHOMEBASE_ENV=staging\nAUTO_UPDATE=true\n' > "$WORK/etc/famhomebase.env"
  HEALTH=healthy; export HEALTH
  unset FAIL_PULL FAIL_HOST RUNNING IMAGE_TAGS NO_OLD_IMAGE
}
update() { sh "$WORK/lib/update.sh" > "$WORK/out" 2>&1; }
version() { tr -d ' \r\n' < "$WORK/lib/VERSION"; }
L="$WORK/lib"; D="$WORK/doc"; E="$WORK/etc"; S="$WORK/state"

fresh 0.1.0; publish 0.1.0; list v0.1.0; update; st=$?
check "up to date: nothing happens" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'up to date at 0.1.0' \$WORK/out && ! grep -q '^pull' \$DOCKER_LOG"

fresh 0.1.0; publish 0.1.0; publish 0.2.0; list v0.1.0 v0.2.0; update; st=$?
check "a newer release is installed: scripts, version, docs and the settings example swapped" "[ $st = 0 ] && [ \"\$(version)\" = 0.2.0 ] && grep -q 'run 0.2.0' $L/run.sh && grep -q 'docs 0.2.0' $D/INSTALL.md && grep -q 'env example 0.2.0' $E/famhomebase.env.example && grep -q 'release 0.2.0' $D/README.md"
check "the image is pulled before anything changes, under the pinned name" "head -n 1 \$DOCKER_LOG | grep -q '^pull ghcr.io/mcesolutionsinc/famhomebase-pi:0.2.0'"
check "the host files are applied with --update" "grep -q 'host-setup 0.2.0 --update' \$WORK/host.log"
check "the settings file is kept" "grep -q 'FAMHOMEBASE_ENV=staging' $E/famhomebase.env"
check "it logs JSON and says what it did" "grep -q '\"component\":\"update\"' \$WORK/out && grep -q 'updated 0.1.0 to 0.2.0' \$WORK/out"
check "nothing of the script's own copy is left in /tmp" "! ls /tmp/tmp.* 2>/dev/null | grep -q update.sh"

fresh 0.1.0; publish 0.2.0; publish 0.10.0; publish 0.3.0; list v0.2.0 v0.10.0 v0.3.0 nightly cloud-v9.9.9 v0.4.0-rc1; update
check "it takes the highest release (0.10.0 beats 0.3.0), and ignores a release candidate and tags that are not versions" "[ \"\$(version)\" = 0.10.0 ]"

fresh 0.1.0; publish 0.2.0; list nightly v1.0.0-beta; update; st=$?
check "no release with a plain version: nothing to do" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ]"

fresh 0.2.0; publish 0.1.0; list v0.1.0; update
check "an older release is never installed" "[ \"\$(version)\" = 0.2.0 ]"

fresh 0.1.0; publish 0.2.0; list v0.2.0; echo 'AUTO_UPDATE=false' >> "$E/famhomebase.env"; update; st=$?
check "AUTO_UPDATE=false only says a release is available" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'release 0.2.0 is available' \$WORK/out"

fresh 0.1.0; update; st=$?
check "offline (no release list): a warning, exit 0, nothing changed" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'could not look up' \$WORK/out"

fresh 0.1.0; publish 0.2.0 badsum; list v0.2.0; update; st=$?
check "a bad checksum changes nothing" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'old run 0.1.0' $L/run.sh && grep -q 'checksum mismatch' \$WORK/out && ! grep -q '^pull' \$DOCKER_LOG"

fresh 0.1.0; publish 0.2.0 badpayload; list v0.2.0; update; st=$?
check "a payload whose VERSION is not the release's is refused" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'not a valid 0.2.0 release' \$WORK/out"

fresh 0.1.0; publish 0.2.0; list v0.2.0; FAIL_PULL=1 update; st=$?
check "an image that cannot be pulled changes nothing" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'old run 0.1.0' $L/run.sh && [ ! -s \$WORK/host.log ]"

fresh 0.1.0; publish 0.2.0; list v0.2.0; HEALTH=unhealthy update; st=$?
check "a display that does not become healthy: everything is put back" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'old run 0.1.0' $L/run.sh && grep -q 'old docs 0.1.0' $D/INSTALL.md && grep -q 'putting the old version back' \$WORK/out"
check "the host files are applied again for the old version after the rollback" "[ \$(grep -c host-setup \$WORK/host.log) = 2 ] && tail -n 1 \$WORK/host.log | grep -q 'host-setup 0.1.0 --update'"
check "the failure is remembered, and not retried for a day" "grep -q '^0.2.0 ' $S/update-failed"
HEALTH=healthy; update; st=$?
check "so the next check leaves it alone" "[ $st = 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'not trying it again' \$WORK/out"
RETRY_AFTER_FAILURE_SECONDS=0 update
check "and after the wait it tries again, and succeeds" "[ \"\$(version)\" = 0.2.0 ] && [ ! -e $S/update-failed ]"

fresh 0.1.0; publish 0.2.0; list v0.2.0; update
check "nothing it wrote is in anyone's home folder: the install, the docs, the settings example and the saved copy are all in the system folders it was given" "[ -f $L/run.sh ] && [ -f $S/rollback/VERSION ] && [ -f $S/rollback/scripts/run.sh ] && grep -q 'old run 0.1.0' $S/rollback/scripts/run.sh && grep -q 'old docs 0.1.0' $S/rollback/doc/INSTALL.md"
fresh 0.1.0; publish 0.2.0; list v0.2.0; HEALTH=unhealthy update
check "a rollback puts back the scripts, docs and settings example, and leaves the settings file alone" "grep -q 'old run 0.1.0' $L/run.sh && grep -q 'old docs 0.1.0' $D/INSTALL.md && grep -q 'old example 0.1.0' $E/famhomebase.env.example && grep -q 'FAMHOMEBASE_ENV=staging' $E/famhomebase.env"

fresh 0.1.0; publish 0.2.0; list v0.2.0; RUNNING=0.1.0 update; st=$?
check "a restart that never happened (the OLD container still running and healthy) does not count as the new version up" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'did not become healthy on 0.2.0' \$WORK/out"

fresh 0.1.0; publish 0.2.0; list v0.2.0; echo 'AUTO_UPDATE="False"' > "$E/famhomebase.env"; printf 'AUTO_UPDATE=No\r\n' >> "$E/famhomebase.env"; update
check "AUTO_UPDATE is read the way it is likely to be written: quotes and capitals are fine" "[ \"\$(version)\" = 0.1.0 ] && grep -q 'AUTO_UPDATE is off' \$WORK/out"
fresh 0.1.0; publish 0.2.0; list v0.2.0; printf 'AUTO_UPDATE=true\r\n' > "$E/famhomebase.env"; update
check "a Windows line ending in .env does not stop an update" "[ \"\$(version)\" = 0.2.0 ]"

fresh 0.1.0; publish 0.2.0; list v0.2.0; echo "0.2.0 not-a-number" > "$S/update-failed"; update; st=$?
check "a half-written failure record is ignored, not fatal" "[ $st = 0 ] && [ \"\$(version)\" = 0.2.0 ]"

fresh 0.1.0; publish 0.2.0; list v0.2.0; IMAGE_TAGS="0.0.9 0.1.0 0.2.0 latest" update
check "after an update the image before the previous one is removed, and this one, the previous one and other tags stay" "grep -q '^rmi ghcr.io/mcesolutionsinc/famhomebase-pi:0.0.9' \$DOCKER_LOG && ! grep -q 'rmi .*:0.1.0' \$DOCKER_LOG && ! grep -q 'rmi .*:0.2.0' \$DOCKER_LOG && ! grep -q 'rmi .*:latest' \$DOCKER_LOG"
fresh 0.1.0; publish 0.2.0; list v0.2.0; HEALTH=unhealthy NO_OLD_IMAGE=1 update
check "a rollback fetches the old image again if it is no longer on the machine" "grep -q '^pull ghcr.io/mcesolutionsinc/famhomebase-pi:0.1.0' \$DOCKER_LOG"
fresh 0.1.0; publish 0.2.0; list v0.2.0; HEALTH=unhealthy update
check "and does not when it is still there" "[ \$(grep -c '^pull ' \$DOCKER_LOG) = 1 ]"

fresh 0.1.0; publish 0.2.0; list v0.2.0; FAIL_HOST=1 update; st=$?
check "applying the new files failing puts the old version back" "[ $st != 0 ] && [ \"\$(version)\" = 0.1.0 ] && grep -q 'old run 0.1.0' $L/run.sh"

fresh 0.1.0; echo 'latest' > "$L/VERSION"; update; st=$?
check "a damaged VERSION stops it" "[ $st != 0 ] && grep -q 'not a version' \$WORK/out"
fresh 0.1.0; FAMHOMEBASE_STATE_DIR=/ sh "$L/update.sh" > "$WORK/out" 2>&1; st=$?
check "it refuses the filesystem root as an install folder" "[ $st != 0 ]"

# the releases list as GitHub may send it: all on one line, and long (the newest well past the 50th)
fresh 0.1.0; publish 0.2.0
mkdir -p "$FIXTURES/repos/$REPO"; { printf '['; i=1; while [ $i -le 80 ]; do printf '{"tag_name":"v0.0.%s"},' "$i"; i=$((i+1)); done; printf '{"tag_name":"v0.2.0"}]'; } > "$FIXTURES/repos/$REPO/releases"
update
check "a compact release list, with the newest release far down it, is read correctly" "[ \"\$(version)\" = 0.2.0 ]"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
