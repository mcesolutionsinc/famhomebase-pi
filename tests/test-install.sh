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
printf '#!/bin/sh\necho "systemctl $*" >> "$DOCKER_LOG"\n[ -n "${NO_SYSTEMD:-}" ] && [ "$2" = daemon-reload ] && exit 1\nexit 0\n' > "$WORK/bin/systemctl"
printf '#!/bin/sh\necho "pkill $*" >> "$DOCKER_LOG"\n' > "$WORK/bin/pkill"
printf '#!/bin/sh\necho "apt-get $*" >> "$DOCKER_LOG"\n' > "$WORK/bin/apt-get"
chmod +x "$WORK/bin/"*

pay="$WORK/pay"; mkdir -p "$pay/scripts"
for v in 0.1.5 0.1.6; do
  rm -rf "$pay"; mkdir -p "$pay/scripts"
  echo "services: {}" > "$pay/docker-compose.yml"; echo "$v" > "$pay/VERSION"
  printf 'FAMHOMEBASE_DIR=/home/pi/famhomebase-pi\nFAMHOMEBASE_PORT=80\nAUTO_UPDATE=true\n' > "$pay/.env.example"
  printf '#!/bin/sh\nmkdir -p secrets && echo KEY > secrets/dashboard.key\n' > "$pay/scripts/generate-key.sh"
  cp "$HERE/../scripts/host-setup.sh" "$pay/scripts/host-setup.sh" # the real one: the installer calls it
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
check "fresh install: port 80, so the addresses have no port" 'grep -q "^FAMHOMEBASE_PORT=80\$" "$WORK/inst/.env" && grep -q "http://localhost/?kiosk=1" "$WORK/out.log" && ! grep -q ":8080" "$WORK/out.log"'

reset; run --dir "$WORK/inst" --version 0.1.5
check "--version installs that release, not the latest" '[ "$(cat "$WORK/inst/VERSION")" = 0.1.5 ]'

reset; run --dir "$WORK/inst" --version 0.1.5; echo "MY-KEY" > "$WORK/inst/secrets/dashboard.key"; echo "AUTO_UPDATE=false" > "$WORK/inst/.env"; mkdir -p "$WORK/inst/data"; echo KEEP > "$WORK/inst/data/config.json"; : > "$WORK/docker.log"
run --dir "$WORK/inst"
check "re-run upgrades to the latest" '[ "$(cat "$WORK/inst/VERSION")" = 0.1.6 ] && grep -q "Updated 0.1.5 -> 0.1.6" "$WORK/out.log"'
check "re-run keeps the key, data and .env" '[ "$(cat "$WORK/inst/secrets/dashboard.key")" = MY-KEY ] && [ "$(cat "$WORK/inst/data/config.json")" = KEEP ] && grep -q "AUTO_UPDATE=false" "$WORK/inst/.env"'
check "re-run adds FAMHOMEBASE_DIR to an old .env that lacked it" 'grep -q "^FAMHOMEBASE_DIR=" "$WORK/inst/.env"'
check "re-run on an .env with no port setting writes the default (80) — no special case for older installs" 'grep -q "^FAMHOMEBASE_PORT=80\$" "$WORK/inst/.env" && [ "$(grep -c "^FAMHOMEBASE_PORT=" "$WORK/inst/.env")" = 1 ] && grep -q "localhost/?kiosk=1" "$WORK/out.log"'

reset; run --dir "$WORK/inst" --no-start
check "--no-start sets up but starts nothing" '[ -f "$WORK/inst/VERSION" ] && ! grep -q "^compose up" "$WORK/docker.log"'

UNIT="$WORK/home/.config/systemd/user/famhomebase-kiosk.service"
reset; run --dir "$WORK/inst" --kiosk
check "--kiosk installs a systemd user service that runs the kiosk script from the install folder" '[ -f "$UNIT" ] && grep -q "^ExecStart=$WORK/inst/scripts/kiosk.sh\$" "$UNIT" && grep -q "^Restart=always\$" "$UNIT" && grep -q "^WantedBy=default.target\$" "$UNIT"'
check "--kiosk: the service itself knows nothing about the port or rotation (the script reads .env)" '! grep -qi "port\|rotate\|8080\|kiosk=1" "$UNIT"'
check "--kiosk reloads systemd and enables and starts the service" 'grep -q "^systemctl --user daemon-reload" "$WORK/docker.log" && grep -q "^systemctl --user enable --now famhomebase-kiosk.service" "$WORK/docker.log"'
check "--kiosk turns on desktop autologin" 'grep -q "raspi-config nonint do_boot_behaviour B4" "$WORK/docker.log"'
check "--kiosk writes no labwc autostart file" '[ ! -e "$WORK/home/.config/labwc/autostart" ]'
if ! command -v wlr-randr >/dev/null 2>&1; then # (skipped on a machine that has it)
  reset; run --dir "$WORK/inst" --kiosk
  check "--kiosk installs the screen rotation tool (wlr-randr) when it is missing" 'grep -q "^apt-get install -y wlr-randr\$" "$WORK/docker.log"'
fi
for tool in wlr-randr; do printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$tool"; chmod +x "$WORK/bin/$tool"; done
reset; run --dir "$WORK/inst" --kiosk
check "--kiosk leaves apt alone when wlr-randr is already there" '! grep -q "^apt-get" "$WORK/docker.log"'
rm -f "$WORK/bin/wlr-randr"
reset; run --dir "$WORK/inst" --kiosk --no-start
check "--kiosk --no-start enables the service but does not start it" 'grep -q "^systemctl --user enable famhomebase-kiosk.service" "$WORK/docker.log" && ! grep -q "enable --now" "$WORK/docker.log"'
reset; run --dir "$WORK/inst"
check "no --kiosk and no old autostart line: the desktop and systemd are left alone" '[ ! -e "$UNIT" ] && ! grep -q "raspi-config\|^systemctl\|^pkill" "$WORK/docker.log"'
reset; ENVV="NO_SYSTEMD=1" run --dir "$WORK/inst" --kiosk; rc=$?
check "no reachable user systemd: the install still succeeds, and says how to enable the service" '[ $rc -eq 0 ] && grep -q "Could not reach your user" "$WORK/out.log" && [ -f "$UNIT" ]'

# an older install opened the dashboard from the labwc autostart: moved to the service automatically
OLDLINE="sh -c 'until curl -sf http://localhost:8080/ >/dev/null; do sleep 2; done; exec chromium-browser --kiosk \"http://localhost:8080/?kiosk=1\"' &"
AS="$WORK/home/.config/labwc/autostart"
reset; mkdir -p "$WORK/home/.config/labwc"; printf '# my own thing\n%s\n%s\nwlr-randr --output HDMI-A-1 --transform 90\n' "# Wait for the dashboard to be up, then open it full-screen on the Pi's display." "$OLDLINE" > "$AS"; run --dir "$WORK/inst"
check "migration: an old autostart kiosk line (and the comment this installer wrote above it) is removed, the owner's other lines stay, the old file is kept" '! grep -q "kiosk=1" "$AS" && ! grep -q "Wait for the dashboard" "$AS" && grep -q "^# my own thing\$" "$AS" && grep -q "^wlr-randr --output HDMI-A-1 --transform 90\$" "$AS" && grep -q "kiosk=1" "$AS.bak"'
check "migration: the service is installed and started, the old browser stopped, and the user is told" '[ -f "$UNIT" ] && grep -q "enable --now famhomebase-kiosk.service" "$WORK/docker.log" && grep -q "^pkill -x chromium" "$WORK/docker.log" && grep -q "Moved the kiosk" "$WORK/out.log"'
: > "$WORK/docker.log"; run --dir "$WORK/inst"
check "migration: run again, nothing left to move" '! grep -q "^pkill" "$WORK/docker.log" && ! grep -q "Moved the kiosk" "$WORK/out.log"'

# rotation
reset; run --dir "$WORK/inst" --rotate 90
check "--rotate 90 is saved in .env for the kiosk script to apply" 'grep -q "^FAMHOMEBASE_ROTATE=90\$" "$WORK/inst/.env"'
run --dir "$WORK/inst" --rotate 270
check "--rotate again replaces it (one line)" '[ "$(grep -c "^FAMHOMEBASE_ROTATE=" "$WORK/inst/.env")" = 1 ] && grep -q "^FAMHOMEBASE_ROTATE=270\$" "$WORK/inst/.env"'
run --dir "$WORK/inst" --rotate normal
check "--rotate normal puts the screen back" 'grep -q "^FAMHOMEBASE_ROTATE=normal\$" "$WORK/inst/.env"'
reset; run --dir "$WORK/inst"
check "no --rotate: the screen is left alone (no setting written)" '! grep -q "FAMHOMEBASE_ROTATE" "$WORK/inst/.env"'
reset; run --dir "$WORK/inst" --kiosk; : > "$WORK/docker.log"; run --dir "$WORK/inst" --rotate 90
check "--rotate on a running kiosk restarts the service so it takes effect" 'grep -q "^systemctl --user restart famhomebase-kiosk.service" "$WORK/docker.log"'
for bad in 45 left "" 1; do
  reset; run --dir "$WORK/inst" --rotate "$bad"; rc=$?
  check "--rotate '$bad' is refused before anything is downloaded" '[ $rc -ne 0 ] && [ ! -e "$WORK/inst/VERSION" ]'
done

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
reset; run --dir "$WORK/inst" --port 9090; run --dir "$WORK/inst"
check "re-running without --port keeps the port you chose" 'grep -q "^FAMHOMEBASE_PORT=9090\$" "$WORK/inst/.env" && grep -q "localhost:9090" "$WORK/out.log"'
reset; run --dir "$WORK/inst" --port 9090; run --dir "$WORK/inst" --port 80
check "--port changes an existing choice, once (no duplicate line)" '[ "$(grep -c "^FAMHOMEBASE_PORT=" "$WORK/inst/.env")" = 1 ] && grep -q "^FAMHOMEBASE_PORT=80\$" "$WORK/inst/.env"'
reset; run --dir "$WORK/inst" --port 80; run --dir "$WORK/inst"
check "an install already on port 80 stays there on re-run" 'grep -q "^FAMHOMEBASE_PORT=80\$" "$WORK/inst/.env" && [ "$(grep -c "^FAMHOMEBASE_PORT=" "$WORK/inst/.env")" = 1 ]'
for bad in abc 0 70000 -1 ""; do
  reset; run --dir "$WORK/inst" --port "$bad"; rc=$?
  check "--port '$bad' is refused before anything is downloaded" '[ $rc -ne 0 ] && [ ! -e "$WORK/inst/VERSION" ]'
done

echo; echo "$n checks, $fail failed"
[ "$fail" -eq 0 ]
