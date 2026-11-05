#!/bin/sh
# Tests for scripts/install.sh with stubbed curl, docker, sudo and raspi-config. Run: sh tests/test-install.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/install.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
REPO=mcesolutionsinc/famhomebase-pi
FIXTURES="$WORK/fx"; mkdir -p "$WORK/bin" "$FIXTURES"

cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) shift; out="$1";; -*) ;; *) url="$1";; esac; shift; done
src="$FIXTURES/${url#*://*/}"
[ -f "$src" ] || exit 22
if [ -z "$out" ]; then cat "$src"; else cp "$src" "$out"; fi
STUB
cat > "$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$DOCKER_LOG"
[ "$1 $2" = "compose version" ] && [ -n "${NO_COMPOSE:-}" ] && exit 1
exit 0
STUB
printf '#!/bin/sh\necho "raspi-config $*" >> "$DOCKER_LOG"\n' > "$WORK/bin/raspi-config"
printf '#!/bin/sh\nexec "$@"\n' > "$WORK/bin/sudo"
chmod +x "$WORK/bin/"*

pay="$WORK/pay"; mkdir -p "$pay/scripts"
for v in 0.1.5 0.1.6; do
  rm -rf "$pay"; mkdir -p "$pay/scripts"
  echo "services: {}" > "$pay/docker-compose.yml"; echo "$v" > "$pay/VERSION"
  printf 'FAMHOMEBASE_DIR=/home/pi/famhomebase-pi\nAUTO_UPDATE=true\n' > "$pay/.env.example"
  printf '#!/bin/sh\nmkdir -p secrets && echo KEY > secrets/dashboard.key\n' > "$pay/scripts/generate-key.sh"
  d="$FIXTURES/$REPO/releases/download/v$v"; mkdir -p "$d"
  tar -czf "$d/famhomebase-pi-$v.tar.gz" -C "$pay" .
  echo "$(sha256sum "$d/famhomebase-pi-$v.tar.gz" | cut -d' ' -f1)  famhomebase-pi-$v.tar.gz" > "$d/famhomebase-pi-$v.tar.gz.sha256"
done
mkdir -p "$FIXTURES/repos/$REPO/releases"; echo '{"tag_name": "v0.1.6"}' > "$FIXTURES/repos/$REPO/releases/latest"

run() { # args to install.sh; env via ENVV
  env PATH="$WORK/bin:$PATH" HOME="$WORK/home" FIXTURES="$FIXTURES" DOCKER_LOG="$WORK/docker.log" \
    GITHUB_API=https://api.github.com GITHUB_DOWNLOAD=https://github.com ${ENVV:-} sh "$SCRIPT" "$@" > "$WORK/out.log" 2>&1
}
reset() { rm -rf "$WORK/home" "$WORK/inst"; mkdir -p "$WORK/home"; : > "$WORK/docker.log"; }

reset; run --dir "$WORK/inst"
check "fresh install: latest release, files in place" '[ "$(cat "$WORK/inst/VERSION")" = 0.1.6 ] && [ -f "$WORK/inst/docker-compose.yml" ]'
check "fresh install: .env points at the install folder" 'grep -q "^FAMHOMEBASE_DIR=$WORK/inst\$" "$WORK/inst/.env" && grep -q "^AUTO_UPDATE=true" "$WORK/inst/.env"'
check "fresh install: encryption key created" '[ -f "$WORK/inst/secrets/dashboard.key" ]'
check "fresh install: pulled and started" 'grep -q "^compose pull" "$WORK/docker.log" && grep -q "^compose up -d" "$WORK/docker.log"'
check "fresh install: tells you where to go next" 'grep -q "http://localhost:8080/?kiosk=1" "$WORK/out.log"'

reset; run --dir "$WORK/inst" --version 0.1.5
check "--version installs that release, not the latest" '[ "$(cat "$WORK/inst/VERSION")" = 0.1.5 ]'

reset; run --dir "$WORK/inst" --version 0.1.5; echo "MY-KEY" > "$WORK/inst/secrets/dashboard.key"; echo "AUTO_UPDATE=false" > "$WORK/inst/.env"; mkdir -p "$WORK/inst/data"; echo KEEP > "$WORK/inst/data/config.json"; : > "$WORK/docker.log"
run --dir "$WORK/inst"
check "re-run upgrades to the latest" '[ "$(cat "$WORK/inst/VERSION")" = 0.1.6 ] && grep -q "Updated 0.1.5 -> 0.1.6" "$WORK/out.log"'
check "re-run keeps the key, data and .env" '[ "$(cat "$WORK/inst/secrets/dashboard.key")" = MY-KEY ] && [ "$(cat "$WORK/inst/data/config.json")" = KEEP ] && grep -q "AUTO_UPDATE=false" "$WORK/inst/.env"'
check "re-run adds FAMHOMEBASE_DIR to an old .env that lacked it" 'grep -q "^FAMHOMEBASE_DIR=" "$WORK/inst/.env"'

reset; run --dir "$WORK/inst" --no-start
check "--no-start sets up but starts nothing" '[ -f "$WORK/inst/VERSION" ] && ! grep -q "^compose up" "$WORK/docker.log"'

reset; run --dir "$WORK/inst" --kiosk
check "--kiosk writes the labwc autostart (chromium, wayland, keyring flag, waits for the dashboard)" 'grep -q "ozone-platform=wayland" "$WORK/home/.config/labwc/autostart" && grep -q "password-store=basic" "$WORK/home/.config/labwc/autostart" && grep -q "until curl" "$WORK/home/.config/labwc/autostart"'
check "--kiosk turns on desktop autologin" 'grep -q "raspi-config nonint do_boot_behaviour B4" "$WORK/docker.log"'
reset; mkdir -p "$WORK/home/.config/labwc"; echo "my old autostart" > "$WORK/home/.config/labwc/autostart"; run --dir "$WORK/inst" --kiosk
check "--kiosk keeps a copy of an existing autostart" '[ "$(cat "$WORK/home/.config/labwc/autostart.bak")" = "my old autostart" ]'
reset; run --dir "$WORK/inst"
check "no --kiosk: leaves the desktop alone" '[ ! -e "$WORK/home/.config/labwc/autostart" ] && ! grep -q raspi-config "$WORK/docker.log"'

reset; badd="$FIXTURES/$REPO/releases/download/v0.1.6"; cp "$badd/famhomebase-pi-0.1.6.tar.gz.sha256" "$WORK/good.sha"; echo "0000  x" > "$badd/famhomebase-pi-0.1.6.tar.gz.sha256"; run --dir "$WORK/inst"; rc=$?
check "bad checksum: installs nothing" '[ $rc -ne 0 ] && [ ! -e "$WORK/inst/VERSION" ] && grep -q "checksum mismatch" "$WORK/out.log"'
cp "$WORK/good.sha" "$badd/famhomebase-pi-0.1.6.tar.gz.sha256"

reset; run --dir "$WORK/inst" --version abc; rc=$?
check "rejects a malformed version" '[ $rc -ne 0 ] && grep -q "not a version" "$WORK/out.log"'
reset; run --dir "$WORK/inst" --version 9.9.9; rc=$?
check "a release that does not exist is a clear error" '[ $rc -ne 0 ] && grep -q "could not download release 9.9.9" "$WORK/out.log"'
reset; ENVV="NO_COMPOSE=1" run --dir "$WORK/inst"; rc=$?
check "no compose plugin: says so before downloading anything" '[ $rc -ne 0 ] && grep -q "Compose plugin is missing" "$WORK/out.log" && [ ! -e "$WORK/inst" ]'
reset; run --bogus; rc=$?
check "unknown option is an error" '[ $rc -ne 0 ] && grep -q "unknown option" "$WORK/out.log"'

# ---- the port
reset; run --dir "$WORK/inst" --port 80
check "--port 80: written to .env, and the URLs have no port" 'grep -q "^FAMHOMEBASE_PORT=80\$" "$WORK/inst/.env" && grep -q "http://localhost/?kiosk=1" "$WORK/out.log" && ! grep -q ":8080" "$WORK/out.log"'
reset; run --dir "$WORK/inst" --port 8081 --kiosk
check "--port 8081 --kiosk: the autostart opens that port (and waits on it)" 'grep -q "localhost:8081/?kiosk=1" "$WORK/home/.config/labwc/autostart" && grep -q "curl -sf http://localhost:8081/" "$WORK/home/.config/labwc/autostart" && ! grep -q "__URL__\|8080" "$WORK/home/.config/labwc/autostart"'
reset; run --dir "$WORK/inst" --port 9090; run --dir "$WORK/inst"
check "re-running without --port keeps the port you chose" 'grep -q "^FAMHOMEBASE_PORT=9090\$" "$WORK/inst/.env" && grep -q "localhost:9090" "$WORK/out.log"'
reset; run --dir "$WORK/inst" --port 9090; run --dir "$WORK/inst" --port 80
check "--port changes an existing choice, once (no duplicate line)" '[ "$(grep -c "^FAMHOMEBASE_PORT=" "$WORK/inst/.env")" = 1 ] && grep -q "^FAMHOMEBASE_PORT=80\$" "$WORK/inst/.env"'
reset; run --dir "$WORK/inst"
check "no --port: 8080, as before" 'grep -q "localhost:8080/?kiosk=1" "$WORK/out.log"'
for bad in abc 0 70000 -1 ""; do
  reset; run --dir "$WORK/inst" --port "$bad"; rc=$?
  check "--port '$bad' is refused before anything is downloaded" '[ $rc -ne 0 ] && [ ! -e "$WORK/inst/VERSION" ]'
done

# ---- refresh-kiosk.sh follows the port in .env
rk="$WORK/rk"; rm -rf "$rk"; mkdir -p "$rk/scripts" "$rk/bin"; cp "$HERE/../scripts/refresh-kiosk.sh" "$rk/scripts/"
for s in pkill sleep id; do printf '#!/bin/sh\nexit 0\n' > "$rk/bin/$s"; done
printf '#!/bin/sh\necho 1000\n' > "$rk/bin/id"
printf '#!/bin/sh\nexec "$@"\n' > "$rk/bin/nohup"
printf '#!/bin/sh\necho "$*" > "$RK_OUT"\n' > "$rk/bin/chromium"
chmod +x "$rk/bin/"*
refresh() { rm -f "$WORK/rk.out"; env PATH="$rk/bin:$PATH" RK_OUT="$WORK/rk.out" sh "$rk/scripts/refresh-kiosk.sh"; i=0; while [ ! -s "$WORK/rk.out" ] && [ $i -lt 20 ]; do i=$((i+1)); sleep 0.1; done; }
printf 'FAMHOMEBASE_PORT=80\nAUTO_UPDATE=true\n' > "$rk/.env"; refresh
check "refresh-kiosk.sh opens the port from .env" 'grep -q "http://localhost:80/?kiosk=1" "$WORK/rk.out"'
rm -f "$rk/.env"; refresh
check "refresh-kiosk.sh defaults to 8080 with no .env" 'grep -q "http://localhost:8080/?kiosk=1" "$WORK/rk.out"'
check "refresh-kiosk.sh keeps the Wayland and keyring flags" 'grep -q "ozone-platform=wayland" "$WORK/rk.out" && grep -q "password-store=basic" "$WORK/rk.out"'

echo; echo "$n checks, $fail failed"
[ "$fail" -eq 0 ]
