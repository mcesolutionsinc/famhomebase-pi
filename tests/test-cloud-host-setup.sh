#!/bin/sh
# Tests for scripts/cloud-host-setup.sh with stubbed systemctl, runuser and raspi-config, writing into scratch folders (no root,
# no systemd). Run: sh tests/test-cloud-host-setup.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/cloud-host-setup.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/bin/sh
echo "system: $*" >> "$CTL_LOG"
[ "${FAIL_RELOAD:-}" = 1 ] && [ "$1" = daemon-reload ] && exit 1
exit 0
STUB
cat > "$WORK/bin/runuser" <<'STUB'
#!/bin/sh
# runuser -u NAME -- env XDG_RUNTIME_DIR=... systemctl --user ARGS
shift 5   # -u NAME -- env XDG=...
shift     # the systemctl path
echo "user: systemctl $*" >> "$CTL_LOG"
[ "${FAIL_USER:-}" = 1 ] && exit 1
exit 0
STUB
cat > "$WORK/bin/raspi-config" <<'STUB'
#!/bin/sh
echo "raspi-config $*" >> "$CTL_LOG"
STUB
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" CTL_LOG="$WORK/ctl.log"
export FAMHOMEBASE_NO_ROOT=1 FAMHOMEBASE_SYSTEMD_DIR="$WORK/system" FAMHOMEBASE_USER_HOME="$WORK/home" FAMHOMEBASE_NM_CONF_DIR="$WORK/nm" FAMHOMEBASE_NET_DIR="$WORK/net"
export SYSTEMCTL="$WORK/bin/systemctl" RUNUSER="$WORK/bin/runuser"

fresh() {
  rm -rf "${WORK:?}/inst" "${WORK:?}/system" "${WORK:?}/home" "${WORK:?}/nm" "${WORK:?}/net"; : > "$CTL_LOG"
  mkdir -p "$WORK/inst/scripts" "$WORK/home" "$WORK/nm"
  cp "$SCRIPT" "$WORK/inst/scripts/"; echo '#!/bin/sh' > "$WORK/inst/scripts/kiosk.sh"; echo 0.1.0 > "$WORK/inst/VERSION"; : > "$WORK/inst/.env"
}
setup() { sh "$WORK/inst/scripts/cloud-host-setup.sh" "$@" > "$WORK/out" 2> "$WORK/err"; }
INST="$WORK/inst"; UNIT="$WORK/system"; KU="$WORK/home/.config/systemd/user/famhomebase-kiosk.service"

fresh; setup; st=$?
check "writes the display unit: runs cloud-run.sh, restarts always, after docker" "[ $st = 0 ] && grep -q \"^ExecStart=/bin/sh $INST/scripts/cloud-run.sh\$\" $UNIT/famhomebase-cloud.service && grep -q '^Restart=always' $UNIT/famhomebase-cloud.service && grep -q '^After=docker.service' $UNIT/famhomebase-cloud.service"
check "the display unit removes the container when it stops" "grep -q 'ExecStopPost=.*docker rm -f famhomebase-display' $UNIT/famhomebase-cloud.service"
check "writes the update service and a timer every 6 hours by default" "grep -q \"^ExecStart=/bin/sh $INST/scripts/cloud-update.sh\$\" $UNIT/famhomebase-cloud-update.service && grep -q '^OnUnitActiveSec=6h' $UNIT/famhomebase-cloud-update.timer"
check "enables and starts the display and the timer" "grep -q 'enable famhomebase-cloud.service famhomebase-cloud-update.timer' \$CTL_LOG && grep -q 'start famhomebase-cloud.service' \$CTL_LOG && grep -q 'start famhomebase-cloud-update.timer' \$CTL_LOG"
check "no kiosk without --kiosk" "[ ! -e $KU ] && ! grep -q '^user:' \$CTL_LOG && ! grep -q raspi-config \$CTL_LOG"

fresh; echo 'CHECK_INTERVAL_HOURS=12' > "$INST/.env"; setup
check "the timer follows CHECK_INTERVAL_HOURS" "grep -q '^OnUnitActiveSec=12h' $UNIT/famhomebase-cloud-update.timer"
fresh; echo 'CHECK_INTERVAL_HOURS=9999' > "$INST/.env"; setup
check "an interval out of range falls back to 6" "grep -q '^OnUnitActiveSec=6h' $UNIT/famhomebase-cloud-update.timer"

fresh; setup --kiosk; st=$?
check "--kiosk writes the kiosk unit for this install's script and turns on desktop autologin" "[ $st = 0 ] && grep -q \"^ExecStart=$INST/scripts/kiosk.sh\$\" $KU && grep -q 'raspi-config nonint do_boot_behaviour B4' \$CTL_LOG"
check "--kiosk enables and starts the kiosk in the user's systemd, and switches off the old line's update watcher" "grep -q 'user: systemctl --user enable --now famhomebase-kiosk.service' \$CTL_LOG && grep -q 'disable --now famhomebase-host.path' \$CTL_LOG"

fresh; mkdir -p "$(dirname "$KU")"; printf '[Service]\nExecStart=/home/pi/famhomebase-pi/scripts/kiosk.sh\n' > "$KU"; setup
check "without --kiosk another install's kiosk service is left alone" "grep -q 'famhomebase-pi/scripts/kiosk.sh' $KU && ! grep -q '^user:' \$CTL_LOG && grep -q 'left the kiosk service alone' \$WORK/out"
setup --kiosk
check "with --kiosk it is taken over" "grep -q \"^ExecStart=$INST/scripts/kiosk.sh\$\" $KU"

fresh; setup --kiosk; : > "$CTL_LOG"; setup --kiosk --update
check "an update that changes nothing does not restart the kiosk, but restarts the display" "! grep -q 'restart famhomebase-kiosk' \$CTL_LOG && grep -q 'system: restart famhomebase-cloud.service' \$CTL_LOG"
echo '# changed' >> "$INST/scripts/kiosk.sh"; : > "$CTL_LOG"; setup --kiosk --update
check "an update that changes the kiosk script restarts the kiosk" "grep -q 'user: systemctl --user restart famhomebase-kiosk.service' \$CTL_LOG"
: > "$CTL_LOG"; setup --kiosk --update
check "and not again the next time" "! grep -q 'restart famhomebase-kiosk' \$CTL_LOG"

fresh; setup --kiosk --no-start
check "--no-start enables but starts nothing" "! grep -q 'start famhomebase' \$CTL_LOG && grep -q 'enable famhomebase-cloud.service' \$CTL_LOG && ! grep -q 'enable --now' \$CTL_LOG"

fresh; FAIL_RELOAD=1 setup; st=$?
check "no reachable systemd is a warning, not a failure" "[ $st = 0 ] && grep -q '\"level\":\"warn\"' \$WORK/out"
fresh; FAIL_USER=1 setup --kiosk; st=$?
check "no reachable user systemd is a warning: the kiosk starts at the next login" "[ $st = 0 ] && grep -q 'next login' \$WORK/out"

fresh; mkdir -p "$WORK/net/wlan0"; setup
check "turns off Wi-Fi power saving on a Pi with Wi-Fi" "grep -q 'wifi.powersave = 2' $WORK/nm/wifi-powersave.conf"
printf '[connection]\nwifi.powersave = 3\n' > "$WORK/nm/wifi-powersave.conf"; setup
check "and keeps a setting of the owner's own" "grep -q 'powersave = 3' $WORK/nm/wifi-powersave.conf"
fresh; setup
check "no Wi-Fi, no file" "[ ! -e $WORK/nm/wifi-powersave.conf ]"

fresh; setup > /dev/null; cp -r "$UNIT" "$WORK/system.1"; setup
check "running it twice changes nothing" "diff -r $UNIT $WORK/system.1 > /dev/null"
fresh; setup --bogus; st=$?
check "an unknown option is refused" "[ $st = 2 ]"
check "its log lines are JSON" "grep -q '^{\"ts\":' \$WORK/out || grep -q '^{\"ts\":' \$WORK/err"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
