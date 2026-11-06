#!/bin/sh
# Tests for scripts/host-setup.sh (the host half of an update) with stubbed systemctl, sudo, apt-get and raspi-config.
# Run: sh tests/test-host-setup.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
INST="$WORK/inst"; BIN="$WORK/bin"; HOME_DIR="$WORK/home"; LOG="$WORK/log"
mkdir -p "$INST/scripts" "$BIN" "$HOME_DIR"
cp "$HERE/../scripts/host-setup.sh" "$INST/scripts/"
echo 0.1.12 > "$INST/VERSION"
echo '#!/bin/sh' > "$INST/scripts/kiosk.sh"; echo '#!/bin/sh' > "$INST/scripts/screen.sh"
UNITS="$HOME_DIR/.config/systemd/user"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
stub systemctl 'echo "systemctl $*" >> "$LOG"'
stub sudo 'echo "sudo $*" >> "$LOG"; [ "${SUDO_FAILS:-}" = 1 ] && exit 1; [ "$1" = -n ] && shift; exec "$@"'
stub apt-get 'echo "apt-get $*" >> "$LOG"'
stub raspi-config 'echo "raspi-config $*" >> "$LOG"'
stub id 'echo 1000'
stub systemctl 'echo "systemctl $*" >> "$LOG"; [ "${KIOSK_ACTIVE:-}" != 1 ] && [ "$2" = is-active ] && exit 3; exit 0'
stub pkill 'echo "pkill $*" >> "$LOG"'
for t in wlr-randr wlopm; do stub $t 'exit 0'; done # the display tools are present unless a test removes them

run() { : > "$LOG"; env PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" LOG="$LOG" "$@" > "$WORK/out" 2>&1; }
setup() { run sh "$INST/scripts/host-setup.sh" "$@"; }

setup --update
check "not a kiosk (no flag, no service, no old autostart line): nothing is touched" '[ ! -d "$UNITS" ] && [ ! -s "$LOG" ]'

setup --kiosk
check "--kiosk writes the kiosk service pointing at the install folder" 'grep -q "^ExecStart=$INST/scripts/kiosk.sh\$" "$UNITS/famhomebase-kiosk.service"'
check "--kiosk writes the update unit: a oneshot service that runs host-setup --update" 'grep -q "^Type=oneshot\$" "$UNITS/famhomebase-host.service" && grep -q "^ExecStart=/bin/sh $INST/scripts/host-setup.sh --update\$" "$UNITS/famhomebase-host.service"'
check "...and a path unit that fires when VERSION changes" 'grep -q "^PathChanged=$INST/VERSION\$" "$UNITS/famhomebase-host.path" && grep -q "^WantedBy=default.target\$" "$UNITS/famhomebase-host.path"'
check "--kiosk reloads systemd, enables the watcher and starts the kiosk" 'grep -q "^systemctl --user daemon-reload" "$LOG" && grep -q "enable famhomebase-host.path" "$LOG" && grep -q "enable --now famhomebase-kiosk.service" "$LOG"'
check "--kiosk turns on desktop autologin" 'grep -q "^raspi-config nonint do_boot_behaviour B4" "$LOG"'
check "a kiosk that was not running is started, not also restarted" '! grep -q "restart famhomebase-kiosk" "$LOG"'

KIOSK_ACTIVE=1
export KIOSK_ACTIVE
setup --update
check "an update that changed nothing: no restart, so the screen does not blink" '! grep -q "restart famhomebase-kiosk" "$LOG"'
check "--update never touches autologin" '! grep -q "raspi-config" "$LOG"'

echo '# a new kiosk script' >> "$INST/scripts/kiosk.sh"
setup --update
check "an update that changed kiosk.sh restarts the kiosk, once" '[ "$(grep -c "restart famhomebase-kiosk" "$LOG")" -eq 1 ] && grep -q "Restarted the kiosk" "$WORK/out"'
setup --update
check "...and not again on the next run" '! grep -q "restart famhomebase-kiosk" "$LOG"'
echo '# a new screen script' >> "$INST/scripts/screen.sh"
setup --update
check "an update that changed screen.sh restarts it too" 'grep -q "restart famhomebase-kiosk" "$LOG"'

setup --kiosk --no-start
check "--no-start enables but neither starts nor restarts anything" '! grep -q "enable --now\|restart\|start famhomebase" "$LOG"'

# the display tools
rm "$BIN/wlopm" "$BIN/wlr-randr"
setup --update
check "after an update, missing display tools are installed with sudo -n (no password prompt, nobody is there to type one)" 'grep -q "^sudo -n apt-get install -y wlr-randr wlopm\$" "$LOG"'
run env SUDO_FAILS=1 sh "$INST/scripts/host-setup.sh" --update
check "if sudo wants a password: carries on and says what to run" '[ $? -eq 0 ] && grep -q "could not install them — run: sudo apt install wlr-randr wlopm" "$WORK/out" && grep -q "daemon-reload" "$LOG"'
setup --kiosk
check "run by hand (--kiosk), it uses plain sudo so it can ask for the password" 'grep -q "^sudo apt-get install -y wlr-randr wlopm\$" "$LOG"'
for t in wlr-randr wlopm; do stub $t 'exit 0'; done
setup --update
check "tools already there: apt is not run" '! grep -q "apt-get" "$LOG"'

# an old install that opened the dashboard from the labwc autostart
rm -rf "$UNITS"; mkdir -p "$HOME_DIR/.config/labwc"
printf '# mine\nchromium --kiosk http://localhost/?kiosk=1\n' > "$HOME_DIR/.config/labwc/autostart"
setup --update
check "an old autostart kiosk line counts as a kiosk: moved to the service, the owner's lines kept, a backup saved" '[ -f "$UNITS/famhomebase-kiosk.service" ] && ! grep -q "kiosk=1" "$HOME_DIR/.config/labwc/autostart" && grep -q "^# mine\$" "$HOME_DIR/.config/labwc/autostart" && [ -f "$HOME_DIR/.config/labwc/autostart.bak" ]'

# systemd not reachable
rm -rf "$UNITS" "$HOME_DIR/.config/labwc"; stub systemctl 'exit 1'
setup --kiosk; rc=$?
check "no reachable user systemd: still succeeds, units are written, and it says how to enable them" '[ $rc -eq 0 ] && [ -f "$UNITS/famhomebase-host.path" ] && grep -q "Could not reach your user" "$WORK/out"'

echo; echo "$n checks, $fail failed"; [ "$fail" -eq 0 ]
