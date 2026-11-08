#!/bin/sh
# Tests for scripts/cloud-install.sh with stubbed curl, docker, systemctl and sudo, and a fake payload (no network, no Docker).
# Run: sh tests/test-cloud-install.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/cloud-install.sh"
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
for t in systemctl sudo; do printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$t"; done
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" CURL="$WORK/bin/curl" DOCKER_LOG="$WORK/docker.log"
export GITHUB_API=https://api.example.test GITHUB_DOWNLOAD=https://dl.example.test
REPO=mcesolutionsinc/famhomebase-pi

publish() { # version [badsum]
  v=$1
  pay="$WORK/pay-$v"; rm -rf "$pay"; mkdir -p "$pay/scripts"
  echo "$v" > "$pay/VERSION"
  cp "$HERE/../.env.cloud.example" "$pay/.env.example"
  printf '#!/bin/sh\necho "host-setup %s $*" >> "%s"\n' "$v" "$WORK/host.log" > "$pay/scripts/cloud-host-setup.sh"
  d="$FIXTURES/$REPO/releases/download/cloud-v$v"; mkdir -p "$d"
  tar -czf "$d/famhomebase-pi-cloud-$v.tar.gz" -C "$pay" .
  sum=$(sha256sum "$d/famhomebase-pi-cloud-$v.tar.gz" | cut -d' ' -f1)
  [ "${2:-}" = badsum ] && sum=0000000000000000000000000000000000000000000000000000000000000000
  echo "$sum  famhomebase-pi-cloud-$v.tar.gz" > "$d/famhomebase-pi-cloud-$v.tar.gz.sha256"
}
list() { mkdir -p "$FIXTURES/repos/$REPO"; : > "$FIXTURES/repos/$REPO/releases"; for t in "$@"; do echo "  {\"tag_name\": \"$t\"}," >> "$FIXTURES/repos/$REPO/releases"; done; }
fresh() { FIXTURES="$WORK/fx"; rm -rf "$FIXTURES" "$WORK/inst" "$WORK/host.log"; mkdir -p "$FIXTURES"; export FIXTURES; : > "$DOCKER_LOG"; : > "$WORK/host.log"; unset FAIL_PULL; publish 0.1.0; list cloud-v0.1.0; }
install() { sh "$SCRIPT" --dir "$WORK/inst" "$@" > "$WORK/out" 2> "$WORK/err"; }
I="$WORK/inst"

fresh; install; st=$?
check "installs the newest cloud release into the folder" "[ $st = 0 ] && [ \"\$(cat $I/VERSION)\" = 0.1.0 ]"
check "writes .env: prod, the production site, port 80, this folder" "grep -q '^FAMHOMEBASE_ENV=prod\$' $I/.env && grep -q '^FAMHOMEBASE_API_URL=https://famhomebase.mc-esolutions.ca\$' $I/.env && grep -q '^FAMHOMEBASE_PORT=80\$' $I/.env && grep -q '^FAMHOMEBASE_DIR=$I\$' $I/.env"
check "pulls the image first, under the release's version" "grep -q '^pull ghcr.io/mcesolutionsinc/famhomebase-pi-cloud:0.1.0\$' \$DOCKER_LOG"
check "runs the host setup for this user, without a kiosk" "grep -q \"host-setup 0.1.0 --user \$(id -un)\$\" \$WORK/host.log"

fresh; install --kiosk --env staging --port 8080; st=$?
check "--kiosk is passed on to the host setup" "[ $st = 0 ] && grep -q -- '--kiosk' \$WORK/host.log"
check "--env staging points at the staging site, and --port is kept" "grep -q '^FAMHOMEBASE_ENV=staging\$' $I/.env && grep -q '^FAMHOMEBASE_API_URL=https://staging.famhomebase.mc-esolutions.ca\$' $I/.env && grep -q '^FAMHOMEBASE_PORT=8080\$' $I/.env"
fresh; install --api-url https://other.example.net; 
check "--api-url wins" "grep -q '^FAMHOMEBASE_API_URL=https://other.example.net\$' $I/.env"

fresh; install --env staging; echo 'AUTO_UPDATE=false' >> "$I/.env"; install --env prod
check "a re-run changes only what was passed: the owner's other choices stay, the environment switches" "grep -q '^AUTO_UPDATE=false\$' $I/.env && grep -q '^FAMHOMEBASE_ENV=prod\$' $I/.env && grep -q '^FAMHOMEBASE_API_URL=https://famhomebase.mc-esolutions.ca\$' $I/.env"
install --port 8080; install
check "and a later re-run keeps the port" "grep -q '^FAMHOMEBASE_PORT=8080\$' $I/.env"

fresh; publish 0.3.0; publish 0.10.0; publish 0.2.0; list cloud-v0.3.0 cloud-v0.10.0 cloud-v0.2.0 v2.0.0 cloud-v0.11.0-rc1; install
check "takes the highest cloud release, ignoring the old line's v* and a release candidate" "[ \"\$(cat $I/VERSION)\" = 0.10.0 ]"
fresh; publish 0.3.0; list cloud-v0.1.0 cloud-v0.3.0; install --version 0.1.0
check "--version picks that release" "[ \"\$(cat $I/VERSION)\" = 0.1.0 ]"
fresh; install --version cloud-v0.1.0
check "--version accepts the tag's own spelling" "[ \"\$(cat $I/VERSION)\" = 0.1.0 ]"

fresh; publish 0.2.0 badsum; list cloud-v0.2.0; install; st=$?
check "a bad checksum installs nothing" "[ $st != 0 ] && [ ! -e $I/VERSION ] && grep -q 'checksum mismatch' \$WORK/err"
fresh; list v1.0.0; install; st=$?
check "no cloud release yet is said plainly" "[ $st != 0 ] && grep -q 'no cloud release' \$WORK/err"
fresh; install --env dev; st=$?
check "an unknown environment is refused before anything is downloaded" "[ $st != 0 ] && [ ! -e $I ]"
fresh; install --api-url https://example.net/path; st=$?
check "an address with a path is refused" "[ $st != 0 ] && [ ! -e $I ]"
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

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
