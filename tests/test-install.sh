#!/bin/sh
# Tests for scripts/install.sh with stubbed curl, docker, systemctl and sudo, and a fake payload (no network, no Docker).
# Run: sh tests/test-install.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/install.sh"
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
[ "$1" = pull ] && [ -n "${FAIL_PULL:-}" ] && exit 1
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/systemctl"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" CURL="$WORK/bin/curl" DOCKER_LOG="$WORK/docker.log"
# where it installs (the real ones are /usr/local/lib/famhomebase and so on), and who "ran sudo"
export FAMHOMEBASE_LIB_DIR="$WORK/lib" FAMHOMEBASE_DOC_DIR="$WORK/doc" FAMHOMEBASE_ETC_DIR="$WORK/etc" FAMHOMEBASE_STATE_DIR="$WORK/state" FAMHOMEBASE_NO_ROOT=1 SUDO_USER=tester
export GITHUB_API=https://api.example.test GITHUB_DOWNLOAD=https://dl.example.test
REPO=mcesolutionsinc/famhomebase-pi

publish() { # version [badsum]
  v=$1
  pay="$WORK/pay-$v"; rm -rf "$pay"; mkdir -p "$pay/lib" "$pay/doc"
  echo "$v" > "$pay/VERSION"
  cp "$HERE/../famhomebase.env.example" "$pay/famhomebase.env.example"
  echo "install guide $v" > "$pay/doc/INSTALL.md"
  echo "run $v" > "$pay/lib/run.sh"
  printf '#!/bin/sh\necho "host-setup %s $*" >> "%s"\n' "$v" "$WORK/host.log" > "$pay/lib/host-setup.sh"
  d="$FIXTURES/$REPO/releases/download/v$v"; mkdir -p "$d"
  tar -czf "$d/famhomebase-pi-$v.tar.gz" -C "$pay" lib doc famhomebase.env.example VERSION
  sum=$(sha256sum "$d/famhomebase-pi-$v.tar.gz" | cut -d' ' -f1)
  [ "${2:-}" = badsum ] && sum=0000000000000000000000000000000000000000000000000000000000000000
  echo "$sum  famhomebase-pi-$v.tar.gz" > "$d/famhomebase-pi-$v.tar.gz.sha256"
}
list() { mkdir -p "$FIXTURES/repos/$REPO"; : > "$FIXTURES/repos/$REPO/releases"; for t in "$@"; do echo "  {\"tag_name\": \"$t\"}," >> "$FIXTURES/repos/$REPO/releases"; done; }
fresh() { FIXTURES="$WORK/fx"; rm -rf "$FIXTURES" "${WORK:?}/lib" "${WORK:?}/doc" "${WORK:?}/etc" "${WORK:?}/state" "$WORK/host.log" "$WORK/legacy.env"; unset FAMHOMEBASE_LEGACY_ENV; mkdir -p "$FIXTURES"; export FIXTURES; : > "$DOCKER_LOG"; : > "$WORK/host.log"; unset FAIL_PULL; publish 0.1.0; list v0.1.0; }
install() { sh "$SCRIPT" "$@" > "$WORK/out" 2> "$WORK/err"; }
L="$WORK/lib"; E="$WORK/etc/famhomebase.env"

fresh; install; st=$?
check "installs the newest release: scripts and VERSION in the lib folder, docs in the doc folder, the settings example in the etc folder" "[ $st = 0 ] && [ \"\$(cat $L/VERSION)\" = 0.1.0 ] && grep -q 'run 0.1.0' $L/run.sh && grep -q 'install guide 0.1.0' $WORK/doc/INSTALL.md && [ -f $WORK/etc/famhomebase.env.example ] && [ -d $WORK/state ]"
check "writes .env: prod, the production site, port 80, this folder" "grep -q '^FAMHOMEBASE_ENV=prod\$' $E && grep -q '^FAMHOMEBASE_API_URL=https://famhomebase.mc-esolutions.ca\$' $E && grep -q '^FAMHOMEBASE_PORT=80\$' $E"
check "pulls the image first, under the release's version" "grep -q '^pull ghcr.io/mcesolutionsinc/famhomebase-pi:0.1.0\$' \$DOCKER_LOG"
check "runs the host setup from the installed folder for the user who ran sudo, without a kiosk" "grep -q \"host-setup 0.1.0 --user tester\$\" \$WORK/host.log"

fresh; install --kiosk --env staging --port 8080; st=$?
check "--kiosk is passed on to the host setup" "[ $st = 0 ] && grep -q -- '--kiosk' \$WORK/host.log"
check "--env staging points at the staging site, and --port is kept" "grep -q '^FAMHOMEBASE_ENV=staging\$' $E && grep -q '^FAMHOMEBASE_API_URL=https://staging.famhomebase.mc-esolutions.ca\$' $E && grep -q '^FAMHOMEBASE_PORT=8080\$' $E"
fresh; install --api-url https://other.example.net; 
check "--api-url wins" "grep -q '^FAMHOMEBASE_API_URL=https://other.example.net\$' $E"

fresh; install --env staging; echo 'AUTO_UPDATE=false' >> "$E"; install --env prod
check "a re-run changes only what was passed: the owner's other choices stay, the environment switches" "grep -q '^AUTO_UPDATE=false\$' $E && grep -q '^FAMHOMEBASE_ENV=prod\$' $E && grep -q '^FAMHOMEBASE_API_URL=https://famhomebase.mc-esolutions.ca\$' $E"
install --port 8080; install
check "and a later re-run keeps the port" "grep -q '^FAMHOMEBASE_PORT=8080\$' $E"

fresh; publish 0.3.0; publish 0.10.0; publish 0.2.0; list v0.3.0 v0.10.0 v0.2.0 nightly cloud-v9.9.9 v0.11.0-rc1; install
check "takes the highest release (0.10.0 beats 0.3.0), ignoring a release candidate and tags that are not versions" "[ \"\$(cat $L/VERSION)\" = 0.10.0 ]"
fresh; publish 0.3.0; list v0.1.0 v0.3.0; install --version 0.1.0
check "--version picks that release" "[ \"\$(cat $L/VERSION)\" = 0.1.0 ]"
fresh; install --version v0.1.0
check "--version accepts the tag's own spelling" "[ \"\$(cat $L/VERSION)\" = 0.1.0 ]"

fresh; publish 0.2.0 badsum; list v0.2.0; install; st=$?
check "a bad checksum installs nothing" "[ $st != 0 ] && [ ! -e $L/VERSION ] && grep -q 'checksum mismatch' \$WORK/err"
fresh; list nightly v1.0.0-beta; install; st=$?
check "no release yet is said plainly" "[ $st != 0 ] && grep -q 'no release' \$WORK/err"
fresh; install --env dev; st=$?
check "an unknown environment is refused before anything is downloaded" "[ $st != 0 ] && [ ! -e $L ]"
fresh; install --api-url https://example.net/path; st=$?
check "an address with a path is refused" "[ $st != 0 ] && [ ! -e $L ]"
fresh; install --api-url http://example.net; st=$?
check "a plain http address is refused" "[ $st != 0 ]"
fresh; install --port 0; st=$?
check "a bad port is refused" "[ $st != 0 ]"
fresh; FAIL_PULL=1 install; st=$?
check "an image that cannot be pulled stops before the host setup, and says why" "[ $st != 0 ] && [ ! -s \$WORK/host.log ] && grep -q 'not public yet' \$WORK/err"
fresh; FAIL_PULL=1 install --no-start; st=$?
check "--no-start does not pull, and passes --no-start on" "[ $st = 0 ] && ! grep -q '^pull' \$DOCKER_LOG && grep -q -- '--no-start' \$WORK/host.log"
fresh; install --bogus; st=$?
check "an unknown option is refused" "[ $st != 0 ]"

# the releases list as GitHub may send it: all on one line, and long
fresh; publish 0.2.0
mkdir -p "$FIXTURES/repos/$REPO"; { printf '['; i=1; while [ $i -le 80 ]; do printf '{"tag_name":"v0.0.%s"},' "$i"; i=$((i+1)); done; printf '{"tag_name":"v0.2.0"}]'; } > "$FIXTURES/repos/$REPO/releases"
install
check "a compact release list, with the newest release far down it, is read correctly" "[ \"\$(cat $L/VERSION)\" = 0.2.0 ]"

# not root (and no test override): refused, and says how to run it
fresh; env -u FAMHOMEBASE_NO_ROOT sh "$SCRIPT" > "$WORK/out" 2> "$WORK/err"; st=$?
check "not run as root: refused with the sudo command, before anything is downloaded" "[ \$(id -u) = 0 ] || { [ $st != 0 ] && grep -q 'needs root' \$WORK/err && [ ! -e $L ]; }"
fresh; SUDO_USER='' install --kiosk --user kid
check "--user names the user whose old desktop kiosk is removed" "grep -q -- '--user kid --kiosk' \$WORK/host.log"

# an install made before 0.3.0 kept its settings in ~/famhomebase/.env
fresh; printf 'FAMHOMEBASE_ENV=staging\nFAMHOMEBASE_API_URL=https://staging.example.net\nFAMHOMEBASE_PORT=8080\nFAMHOMEBASE_DIR=/home/x/famhomebase\nAUTO_UPDATE=false\n' > "$WORK/legacy.env"
FAMHOMEBASE_LEGACY_ENV="$WORK/legacy.env" install; st=$?
check "settings from the old folder are taken over (environment, address, auto-update), but not the port or the folder" "[ $st = 0 ] && grep -q '^FAMHOMEBASE_ENV=staging\$' $E && grep -q '^FAMHOMEBASE_API_URL=https://staging.example.net\$' $E && grep -q '^AUTO_UPDATE=false\$' $E && grep -q '^FAMHOMEBASE_PORT=80\$' $E && ! grep -q '^FAMHOMEBASE_DIR' $E && grep -q 'not used any more' \$WORK/out"
check "and the old folder is left alone (the owner deletes it)" "[ -f $WORK/legacy.env ]"
FAMHOMEBASE_LEGACY_ENV="$WORK/legacy.env" install --env prod
check "the old settings are taken over only the first time: a re-run does not bring them back" "grep -q '^FAMHOMEBASE_ENV=prod\$' $E && grep -q '^FAMHOMEBASE_API_URL=https://famhomebase.mc-esolutions.ca\$' $E"

# the files that were there before are replaced, not mixed with the new ones
fresh; install; echo old > "$L/leftover.sh"; install
check "an older install's scripts do not linger beside the new ones" "[ ! -e $L/leftover.sh ] && [ -f $L/run.sh ]"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
