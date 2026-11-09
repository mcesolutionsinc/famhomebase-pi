#!/bin/sh
# Tests for scripts/host-setup.sh with stubbed systemctl, runuser and raspi-config, writing into scratch folders (no root,
# no systemd). Run: sh tests/test-host-setup.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/host-setup.sh"
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
case "$*" in *is-active*) [ "${ACTIVE:-}" = 1 ]; exit $? ;; esac
exit 0
STUB
cat > "$WORK/bin/runuser" <<'STUB'
#!/bin/sh
# runuser -u NAME -- env XDG_RUNTIME_DIR=... systemctl --user ARGS
shift 5   # -u NAME -- env XDG=...
shift     # the systemctl path
echo "user: systemctl $*" >> "$CTL_LOG"
[ "${FAIL_USER:-}" = 1 ] && exit 1
case "$*" in *is-active*) [ "${ACTIVE:-}" = 1 ]; exit $? ;; esac
exit 0
STUB
cat > "$WORK/bin/raspi-config" <<'STUB'
#!/bin/sh
echo "raspi-config $*" >> "$CTL_LOG"
STUB
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" CTL_LOG="$WORK/ctl.log"
export FAMHOMEBASE_ETC_DIR="$WORK/etc" FAMHOMEBASE_STATE_DIR="$WORK/state" FAMHOMEBASE_BIN_DIR="$WORK/usrbin"
export FAMHOMEBASE_NO_ROOT=1 FAMHOMEBASE_SYSTEMD_DIR="$WORK/system" FAMHOMEBASE_USER_HOME="$WORK/home" FAMHOMEBASE_NM_CONF_DIR="$WORK/nm" FAMHOMEBASE_NET_DIR="$WORK/net"
export SYSTEMCTL="$WORK/bin/systemctl" RUNUSER="$WORK/bin/runuser"

fresh() {
  rm -rf "${WORK:?}/inst" "${WORK:?}/system" "${WORK:?}/home" "${WORK:?}/nm" "${WORK:?}/net" "${WORK:?}/etc" "${WORK:?}/state" "${WORK:?}/usrbin"; : > "$CTL_LOG"
  mkdir -p "$WORK/inst" "$WORK/home" "$WORK/nm" "$WORK/etc"
  cp "$SCRIPT" "$WORK/inst/"; echo '#!/bin/sh' > "$WORK/inst/kiosk.sh"; echo '#!/bin/sh' > "$WORK/inst/famhomebase"; echo 0.1.0 > "$WORK/inst/VERSION"; : > "$ETC/famhomebase.env"
}
setup() { sh "$WORK/inst/host-setup.sh" "$@" > "$WORK/out" 2> "$WORK/err"; }
INST="$WORK/inst"; ETC="$WORK/etc"; STATE="$WORK/state"; BIN="$WORK/usrbin"; UNIT="$WORK/system"; KU="$WORK/home/.config/systemd/user/famhomebase-kiosk.service"

fresh; setup; st=$?
check "writes the display unit: runs run.sh, restarts always, after docker" "[ $st = 0 ] && grep -Fxq 'ExecStart=/bin/sh \"$INST/run.sh\"' $UNIT/famhomebase.service && grep -q '^Restart=always' $UNIT/famhomebase.service && grep -q '^After=docker.service' $UNIT/famhomebase.service"
check "the folder is quoted in the unit, so a path with odd characters still starts" "grep -q 'ExecStart=/bin/sh \"' $UNIT/famhomebase.service"
check "the display unit removes the container when it stops" "grep -q 'ExecStopPost=.*docker rm -f famhomebase-display' $UNIT/famhomebase.service"
check "writes the update service and a timer every 6 hours by default" "grep -Fxq 'ExecStart=/bin/sh \"$INST/update.sh\"' $UNIT/famhomebase-update.service && grep -q '^OnUnitActiveSec=6h' $UNIT/famhomebase-update.timer"
check "enables and starts the display and the timer" "grep -q 'enable famhomebase.service famhomebase-update.timer' \$CTL_LOG && grep -q 'system: start famhomebase.service' \$CTL_LOG && ! grep -q 'system: restart famhomebase.service' \$CTL_LOG && grep -q 'start famhomebase-update.timer' \$CTL_LOG"
check "no kiosk without --kiosk" "[ ! -e $KU ] && ! grep -q '^user:' \$CTL_LOG && ! grep -q raspi-config \$CTL_LOG"

check "makes the state folder and the famhomebase command (a link to the one in the install)" "[ -d $STATE ] && [ \"\$(readlink $BIN/famhomebase)\" = $INST/famhomebase ]"
check "no kiosk profile folder without --kiosk" "[ ! -e $STATE/kiosk-profile ]"
fresh; ACTIVE=1 setup
check "installing over a running display restarts it, so it runs what was just written" "grep -q 'system: restart famhomebase.service' \$CTL_LOG"
fresh; setup --kiosk
check "--kiosk makes the kiosk's browser profile folder in the state folder, for the kiosk user" "[ -d $STATE/kiosk-profile ] && [ \$(stat -c %U $STATE/kiosk-profile) = \$(id -un) ]"

fresh; echo 'CHECK_INTERVAL_HOURS=12' > "$ETC/famhomebase.env"; setup
check "the timer follows CHECK_INTERVAL_HOURS" "grep -q '^OnUnitActiveSec=12h' $UNIT/famhomebase-update.timer"
fresh; echo 'CHECK_INTERVAL_HOURS=9999' > "$ETC/famhomebase.env"; setup
check "an interval out of range falls back to 6" "grep -q '^OnUnitActiveSec=6h' $UNIT/famhomebase-update.timer"

fresh; setup --kiosk; st=$?
check "--kiosk writes the kiosk unit for this install's script and turns on desktop autologin" "[ $st = 0 ] && grep -Fxq 'ExecStart=\"$INST/kiosk.sh\"' $KU && grep -q 'raspi-config nonint do_boot_behaviour B4' \$CTL_LOG"
check "--kiosk enables and starts the kiosk in the user's systemd, and switches off an older install's update watcher" "grep -q 'user: systemctl --user enable --now famhomebase-kiosk.service' \$CTL_LOG && grep -q 'disable --now famhomebase-host.path' \$CTL_LOG"

fresh; mkdir -p "$(dirname "$KU")"; printf '[Service]\nExecStart=/home/pi/famhomebase-pi/scripts/kiosk.sh\n' > "$KU"; setup
check "without --kiosk another install's kiosk service is left alone" "grep -q 'famhomebase-pi/scripts/kiosk.sh' $KU && ! grep -q '^user:' \$CTL_LOG && grep -q 'left the kiosk service alone' \$WORK/out"
setup --kiosk
check "with --kiosk it is taken over" "grep -Fxq 'ExecStart=\"$INST/kiosk.sh\"' $KU"

fresh; rm -rf "${WORK:?}/home"; mkdir "$WORK/home"; setup --kiosk
check "folders made on the way to the user's kiosk unit are the user's (not left as root's)" "[ \$(stat -c %U $WORK/home/.config/systemd/user) = \$(id -un) ]"

fresh; setup --kiosk; : > "$CTL_LOG"; setup --kiosk --update
check "an update that changes nothing does not restart the kiosk, but restarts the display" "! grep -q 'restart famhomebase-kiosk' \$CTL_LOG && grep -q 'system: restart famhomebase.service' \$CTL_LOG"
echo '# changed' >> "$INST/kiosk.sh"; : > "$CTL_LOG"; setup --kiosk --update
check "an update that changes the kiosk script restarts the kiosk" "grep -q 'user: systemctl --user restart famhomebase-kiosk.service' \$CTL_LOG"
: > "$CTL_LOG"; setup --kiosk --update
check "and not again the next time" "! grep -q 'restart famhomebase-kiosk' \$CTL_LOG"

fresh; setup --kiosk
check "a fresh --kiosk install starts the kiosk once, without restarting it straight away" "grep -q 'enable --now famhomebase-kiosk.service' \$CTL_LOG && ! grep -q 'restart famhomebase-kiosk' \$CTL_LOG"
fresh; ACTIVE=1 setup --kiosk
check "a kiosk that was already running (on an older install) is moved onto the new files with a restart" "grep -q 'user: systemctl --user restart famhomebase-kiosk.service' \$CTL_LOG"

fresh; mkdir -p "$UNIT"; for u in famhomebase-cloud.service famhomebase-cloud-update.service famhomebase-cloud-update.timer; do echo old > "$UNIT/$u"; done; setup
check "the units of an earlier install named cloud are disabled and removed, so they do not fight the new ones for the container name and the port" "[ ! -e $UNIT/famhomebase-cloud.service ] && [ ! -e $UNIT/famhomebase-cloud-update.timer ] && [ ! -e $UNIT/famhomebase-cloud-update.service ] && grep -q 'disable --now famhomebase-cloud.service' \$CTL_LOG && grep -q 'removed the older unit famhomebase-cloud.service' \$WORK/out && [ -f $UNIT/famhomebase.service ]"
fresh; setup
check "and with none of the older units there is nothing to remove" "! grep -q 'removed the older unit' \$WORK/out"

# not root: it runs itself again under sudo, and must hand sudo the same options (they used to be lost, so --kiosk did nothing)
printf '#!/bin/sh\necho "sudo $*" >> "$CTL_LOG"\n' > "$WORK/bin/sudo"; chmod +x "$WORK/bin/sudo"
printf '#!/bin/sh\ncase "$1" in -un) echo tester ;; *) echo 1000 ;; esac\n' > "$WORK/bin/id"; chmod +x "$WORK/bin/id"
fresh; env -u FAMHOMEBASE_NO_ROOT sh "$INST/host-setup.sh" --kiosk --no-start > "$WORK/out" 2>&1
check "run as a normal user, it runs itself again under sudo with the same options and the user's name" "grep -q \"^sudo sh $INST/host-setup.sh --kiosk --no-start --user tester\\$\" \$CTL_LOG"
env -u FAMHOMEBASE_NO_ROOT sh "$INST/host-setup.sh" > "$WORK/out" 2>&1; env -u FAMHOMEBASE_NO_ROOT sh "$INST/host-setup.sh" --update >/dev/null 2>&1
check "with no options it passes none on, and --update is kept" "grep -q '^sudo sh $INST/host-setup.sh --user tester\$' \$CTL_LOG && grep -q '^sudo sh $INST/host-setup.sh --update --user tester\$' \$CTL_LOG"
rm -f "$WORK/bin/sudo" "$WORK/bin/id"

fresh; setup --kiosk --no-start
check "--no-start enables but starts nothing" "! grep -q 'start famhomebase' \$CTL_LOG && grep -q 'enable famhomebase.service' \$CTL_LOG && ! grep -q 'enable --now' \$CTL_LOG"

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
