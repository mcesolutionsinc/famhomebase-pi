#!/bin/sh
# Tests for scripts/host-setup.sh with stubbed systemctl, runuser, apt-get, useradd and chown, writing into scratch folders (no root,
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
case "$*" in
  *get-default*) echo "${DEFAULT_TARGET:-graphical.target}"; exit 0 ;;
  *is-active*) case "$*" in *display-manager*) [ "${DESKTOP_UP:-}" = 1 ]; exit $? ;; *) [ "${ACTIVE:-}" = 1 ]; exit $? ;; esac ;;
esac
exit 0
STUB
cat > "$WORK/bin/runuser" <<'STUB'
#!/bin/sh
# runuser -u NAME -- env XDG_RUNTIME_DIR=... systemctl --user ARGS
shift 5   # -u NAME -- env XDG=...
shift     # the systemctl path
echo "user: systemctl $*" >> "$CTL_LOG"
exit 0
STUB
printf '#!/bin/sh\necho "apt-get $*" >> "$CTL_LOG"\n[ -z "${FAIL_APT:-}" ]\n' > "$WORK/bin/apt-get"
printf '#!/bin/sh\necho "useradd $*" >> "$CTL_LOG"\n[ -z "${FAIL_USERADD:-}" ]\n' > "$WORK/bin/useradd"
printf '#!/bin/sh\necho "chown $*" >> "$CTL_LOG"\n' > "$WORK/bin/chown"
printf '#!/bin/sh\necho "usermod $*" >> "$CTL_LOG"\n' > "$WORK/bin/usermod"
printf '#!/bin/sh\necho "pkill $*" >> "$CTL_LOG"\n' > "$WORK/bin/pkill"
printf '#!/bin/sh\n[ "$1" = group ] && exit 0\nexec /usr/bin/getent "$@"\n' > "$WORK/bin/getent"
chmod +x "$WORK/bin/"*
# the tools the kiosk needs, as far as `command -v` can tell: cage and chromium are "installed" unless a test removes them
# a PATH with only the system tools the script uses (and the stubs), for the tests where cage and the browser must be missing: a
# machine that has a browser installed (a CI runner does) must not leak in
mkdir -p "$WORK/min"
for t in sh id sed tail head tr cat cmp mkdir rm mv ln cksum date stat grep cut dirname readlink env tee basename; do ln -sf "$(command -v $t)" "$WORK/min/$t" 2>/dev/null; done
MINPATH="$WORK/bin:$WORK/min"
mkdir -p "$WORK/tools"; printf '#!/bin/sh\n' > "$WORK/tools/cage"; printf '#!/bin/sh\n' > "$WORK/tools/chromium"; printf '#!/bin/sh\n' > "$WORK/tools/swayimg"; chmod +x "$WORK/tools/"*
export PATH="$WORK/bin:$WORK/tools:$PATH" CTL_LOG="$WORK/ctl.log"
export FAMHOMEBASE_BOOT_DIR="$WORK/boot" FAMHOMEBASE_ETC_DIR="$WORK/etc" FAMHOMEBASE_STATE_DIR="$WORK/state" FAMHOMEBASE_BIN_DIR="$WORK/usrbin"
export FAMHOMEBASE_NO_ROOT=1 FAMHOMEBASE_SYSTEMD_DIR="$WORK/system" FAMHOMEBASE_USER_HOME="$WORK/home" FAMHOMEBASE_NM_CONF_DIR="$WORK/nm" FAMHOMEBASE_NET_DIR="$WORK/net" FAMHOMEBASE_CHROMIUM_POLICY_DIRS="$WORK/policy $WORK/policy-old/chromium-browser"
export FAMHOMEBASE_HOMES="$WORK/home" SYSTEMCTL="$WORK/bin/systemctl" RUNUSER="$WORK/bin/runuser" APT_GET="$WORK/bin/apt-get" USERADD="$WORK/bin/useradd" USERMOD="$WORK/bin/usermod" CHOWN="$WORK/bin/chown"

fresh() {
  rm -rf "${WORK:?}/inst" "${WORK:?}/system" "${WORK:?}/home" "${WORK:?}/nm" "${WORK:?}/net" "${WORK:?}/etc" "${WORK:?}/state" "${WORK:?}/usrbin"; : > "$CTL_LOG"
  mkdir -p "$WORK/inst" "$WORK/home" "$WORK/nm" "$WORK/etc"
  cp "$SCRIPT" "$WORK/inst/"; echo '#!/bin/sh' > "$WORK/inst/kiosk.sh"; echo '#!/bin/sh' > "$WORK/inst/warm.sh"; echo '#!/bin/sh' > "$WORK/inst/load-image.sh"; echo '#!/bin/sh' > "$WORK/inst/bootconfig.sh"; echo '#!/bin/sh' > "$WORK/inst/famhomebase"; printf '#!/bin/sh\necho "splash $*" >> "%s"\n[ -z "${FAIL_SPLASH:-}" ]\n' "$CTL_LOG" > "$WORK/inst/splash.sh"; echo 0.1.0 > "$WORK/inst/VERSION"; : > "$ETC/famhomebase.env"
  mkdir -p "$WORK/inst/cursors/famhomebase-blank/cursors"; echo cursor > "$WORK/inst/cursors/famhomebase-blank/cursors/left_ptr"
  unset FAIL_SPLASH FAIL_RELOAD ACTIVE DESKTOP_UP DEFAULT_TARGET FAIL_APT FAIL_USERADD
}
setup() { sh "$WORK/inst/host-setup.sh" "$@" > "$WORK/out" 2> "$WORK/err"; }
INST="$WORK/inst"; ETC="$WORK/etc"; STATE="$WORK/state"; BIN="$WORK/usrbin"; UNIT="$WORK/system"; KU="$UNIT/famhomebase-kiosk.service"
OLD="$WORK/home/.config/systemd/user/famhomebase-kiosk.service"

fresh; setup; st=$?
check "writes the display unit: runs run.sh, restarts always, after docker" "[ $st = 0 ] && grep -Fxq 'ExecStart=/bin/sh \"$INST/run.sh\"' $UNIT/famhomebase.service && grep -q '^Restart=always' $UNIT/famhomebase.service && grep -q '^After=docker.service' $UNIT/famhomebase.service"
check "the folder is quoted in the unit, so a path with odd characters still starts" "grep -q 'ExecStart=/bin/sh \"' $UNIT/famhomebase.service"
check "the display unit does not wait for the network (the container needs none; the page copes with a late connection), so the screen is not held up" "! grep -q 'network-online' $UNIT/famhomebase.service"
check "the display unit removes the container when it stops" "grep -q 'ExecStopPost=.*docker rm -f famhomebase-display' $UNIT/famhomebase.service"
check "writes the update service and a timer every 6 hours by default" "grep -Fxq 'ExecStart=/bin/sh \"$INST/update.sh\"' $UNIT/famhomebase-update.service && grep -q '^OnUnitActiveSec=6h' $UNIT/famhomebase-update.timer"
check "enables and starts the display and the timer" "grep -q 'enable famhomebase.service famhomebase-update.timer' \$CTL_LOG && grep -q 'system: start famhomebase.service' \$CTL_LOG && ! grep -q 'system: restart famhomebase.service' \$CTL_LOG && grep -q 'start famhomebase-update.timer' \$CTL_LOG"
check "no kiosk without --kiosk: no unit, no packages, no user, no change of the boot target" "[ ! -e $KU ] && ! grep -q 'apt-get\\|useradd\\|set-default' \$CTL_LOG && [ ! -e $STATE/kiosk-profile ]"
check "makes the state folder and the famhomebase command (a link to the one in the install)" "[ -d $STATE ] && [ \"\$(readlink $BIN/famhomebase)\" = $INST/famhomebase ]"
fresh; ACTIVE=1 setup
check "installing over a running display restarts it, so it runs what was just written" "grep -q 'system: restart famhomebase.service' \$CTL_LOG"

fresh; echo 'CHECK_INTERVAL_HOURS=12' > "$ETC/famhomebase.env"; setup
check "the timer follows CHECK_INTERVAL_HOURS" "grep -q '^OnUnitActiveSec=12h' $UNIT/famhomebase-update.timer"
fresh; echo 'CHECK_INTERVAL_HOURS=9999' > "$ETC/famhomebase.env"; setup
check "an interval out of range falls back to 6" "grep -q '^OnUnitActiveSec=6h' $UNIT/famhomebase-update.timer"

# --- the kiosk
fresh; setup --kiosk; st=$?
check "--kiosk writes the kiosk as a system unit: cage running this install's kiosk.sh, as its own user, on the first terminal" "[ $st = 0 ] && grep -Fxq 'ExecStart=/usr/bin/cage -- \"$INST/kiosk.sh\"' $KU && grep -q '^User=famhomebase-kiosk' $KU && grep -q '^TTYPath=/dev/tty1' $KU && grep -q '^PAMName=login' $KU && grep -q '^Restart=always' $KU"
check "the kiosk brings terminal 1 to the front first (a desktop may have left another there), and ignores a failure of that" "grep -q '^ExecStartPre=-+/usr/bin/chvt 1' $KU"
check "the kiosk stops the login prompt itself and has no Conflicts= on it (a prompt started by the first-boot user step cancelled the kiosk's start)" "grep -Fxq 'ExecStartPre=-+/bin/systemctl stop getty@tty1.service' $KU && ! grep -q '^Conflicts=getty' $KU"
check "the kiosk is enabled and started, and boots to the text target (no login manager at boot)" "grep -q 'system: enable famhomebase-kiosk.service' \$CTL_LOG && grep -q 'system: start famhomebase-kiosk.service' \$CTL_LOG && grep -q 'system: set-default multi-user.target' \$CTL_LOG"
check "it makes the service user (a system user with no shell) and gives it the browser profile folder" "grep -q '^useradd --system --home-dir $STATE/kiosk-home --create-home --shell /usr/sbin/nologin' \$CTL_LOG && [ -d $STATE/kiosk-profile ] && grep -q '^chown -R famhomebase-kiosk $STATE/kiosk-profile' \$CTL_LOG"
check "with cage and the browser already there, nothing is installed" "! grep -q '^apt-get' \$CTL_LOG"
fresh; DEFAULT_TARGET=multi-user.target setup --kiosk
check "a Pi already booting to the text target is not changed" "! grep -q 'set-default' \$CTL_LOG"
fresh; DESKTOP_UP=1 setup --kiosk
check "a desktop that is running is stopped before the kiosk starts, so it does not hold the screen" "grep -n 'stop display-manager' \$CTL_LOG | head -1 | cut -d: -f1 | grep -q . && [ \"\$(grep -n 'stop display-manager' \$CTL_LOG | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'start famhomebase-kiosk' \$CTL_LOG | head -1 | cut -d: -f1)\" ]"
fresh; mkdir -p "$WORK/tools2"; PATH="$MINPATH" setup --kiosk
check "cage and the browser missing: installed with apt, then the kiosk is set up" "grep -q '^apt-get install -y -q cage' \$CTL_LOG && grep -q '^apt-get install -y -q chromium' \$CTL_LOG && grep -q '^apt-get install -y -q swayimg' \$CTL_LOG && [ -f $KU ]"
fresh; FAIL_APT=1 PATH="$MINPATH" setup --kiosk; st=$?
check "a package that cannot be installed is a warning that says what to do, not a failure" "[ $st = 0 ] && grep -q 'could not install cage' \$WORK/out"
fresh; FAIL_USERADD=1 setup --kiosk; st=$?
check "a user that cannot be made is a warning" "[ $st = 0 ] && grep -q 'could not make the user famhomebase-kiosk' \$WORK/out"

# the kiosk of an earlier install ran in a user's desktop
fresh; mkdir -p "$(dirname "$OLD")"; printf '[Service]\nExecStart="/home/pi/famhomebase/scripts/kiosk.sh"\n' > "$OLD"; setup --kiosk --user tester
check "the old desktop kiosk service of the user is stopped, disabled and removed, so it does not fight the new one" "[ ! -e $OLD ] && grep -q 'user: systemctl --user disable --now famhomebase-kiosk.service' \$CTL_LOG && grep -q 'removed the old desktop kiosk service' \$WORK/out"
fresh; mkdir -p "$WORK/home/x/.config/systemd/user" "$STATE"; printf '[Service]\nExecStart=x\n' > "$WORK/home/x/.config/systemd/user/famhomebase-kiosk.service"; echo sum > "$STATE/host-applied"; FAMHOMEBASE_HOMES="$WORK/home/x" setup --update
check "an update of an install before 0.4.0 (a kiosk by the note it left, no --user) finds the old desktop kiosk service in a home folder and removes it" "[ ! -e $WORK/home/x/.config/systemd/user/famhomebase-kiosk.service ] && [ -f $KU ] && grep -q 'user: systemctl --user disable --now famhomebase-kiosk.service' \$CTL_LOG"
fresh; mkdir -p "$(dirname "$OLD")"; printf '[Service]\nExecStart=x\n' > "$OLD"; setup --user tester
check "without --kiosk (and no kiosk of ours) it is left alone" "[ -e $OLD ] && ! grep -q '^user:' \$CTL_LOG"

# the boot splash
fresh; setup --kiosk
check "--kiosk sets up the boot splash (the packages, the boot settings, the theme)" "grep -q '^splash install' \$CTL_LOG"
check "and writes the unit that makes the theme again when the page writes a new rotation: a path unit on the rotation file, and the service it runs" "grep -q '^PathChanged=$STATE/state/rotation' $UNIT/famhomebase-splash.path && grep -q '^Unit=famhomebase-splash.service' $UNIT/famhomebase-splash.path && grep -Fxq 'ExecStart=/bin/sh \"$INST/splash.sh\" apply' $UNIT/famhomebase-splash.service && grep -q 'enable famhomebase-splash.path' \$CTL_LOG && grep -q 'start famhomebase-splash.path' \$CTL_LOG"
check "plymouth keeps the last picture on the screen when it quits, and the kiosk starts after plymouth has left (cage cannot have the screen before)" "grep -q 'plymouth quit --retain-splash' $UNIT/plymouth-quit.service.d/famhomebase.conf && grep -q '^After=.*plymouth-quit.service plymouth-quit-wait.service' $KU"
fresh; setup --kiosk; sed -i 's/^PathChanged=.*/PathChanged=\/old/' "$UNIT/famhomebase-splash.path"; : > "$CTL_LOG"; setup --kiosk --update
check "a splash unit that changed is restarted, so the running watch follows it" "grep -q 'system: restart famhomebase-splash.path' \$CTL_LOG"
fresh; setup --kiosk; : > "$CTL_LOG"; setup --kiosk --update
check "and one that did not change is only started (it already runs)" "! grep -q 'restart famhomebase-splash.path' \$CTL_LOG"
fresh; setup --kiosk
check "cloud-init's console output stays in the journal, so no text shows on the screen after the splash" "for s in cloud-init-local cloud-init-network cloud-config cloud-final; do grep -q '^StandardOutput=journal\$' $UNIT/\$s.service.d/famhomebase-quiet.conf || exit 1; done"
check "the browser's window gets the page's dark colour by policy, so it does not flash white" "grep -q '\"BrowserThemeColor\": \"#0A1327\"' $WORK/policy/famhomebase.json && grep -q 'BrowserThemeColor' $WORK/policy-old/chromium-browser/famhomebase.json"
check "the terminal's text cursor is switched off before the screen is handed to cage (the escape codes for cursor off are in the unit as written)" "grep -q '^ExecStartPre=.*printf.*033\\[?25l.*/dev/tty1' $KU"
check "the warm-up unit reads the browser's files at the lowest priority and is enabled" "grep -Fxq 'ExecStart=/bin/sh \"$INST/warm.sh\"' $UNIT/famhomebase-warm.service && grep -q '^IOSchedulingClass=idle' $UNIT/famhomebase-warm.service && grep -q '^Nice=19' $UNIT/famhomebase-warm.service && grep -q 'enable .*famhomebase-warm.service' \$CTL_LOG"
check "the theme named default is the blank cursor theme, since cage ignores XCURSOR_THEME for its own pointer" "[ \"\$(readlink $INST/cursors/default)\" = famhomebase-blank ]"
check "the first-boot image loader: a unit that runs load-image.sh only when the saved image file exists, before the display, and is enabled" "grep -Fxq 'ExecStart=/bin/sh \"$INST/load-image.sh\"' $UNIT/famhomebase-image-load.service && grep -Fxq 'ConditionPathExists=$STATE/image.tar.gz' $UNIT/famhomebase-image-load.service && grep -q '^Before=famhomebase.service' $UNIT/famhomebase-image-load.service && grep -q 'enable famhomebase-image-load.service' \$CTL_LOG"
check "the boot-drive settings step: a unit that runs bootconfig.sh only when famhomebase.env is on the boot drive, after the drive is mounted, before the display, and is enabled" "grep -Fxq 'ExecStart=/bin/sh \"$INST/bootconfig.sh\"' $UNIT/famhomebase-bootconfig.service && grep -Fxq 'ConditionPathExists=$WORK/boot/famhomebase.env' $UNIT/famhomebase-bootconfig.service && grep -Fxq 'RequiresMountsFor=$WORK/boot' $UNIT/famhomebase-bootconfig.service && grep -q '^Before=famhomebase.service' $UNIT/famhomebase-bootconfig.service && grep -q 'enable famhomebase-bootconfig.service' \$CTL_LOG"
check "the splash waits for the page: a ready unit runs ready.sh, and plymouth is ordered after it, and the kiosk too" "grep -Fxq 'ExecStart=/bin/sh \"$INST/ready.sh\"' $UNIT/famhomebase-ready.service && grep -q '^After=famhomebase-ready.service' $UNIT/plymouth-quit.service.d/famhomebase.conf && grep -q '^Wants=famhomebase-ready.service' $UNIT/plymouth-quit.service.d/famhomebase.conf && grep -q '^After=.*famhomebase-ready.service' $KU && grep -q 'enable .*famhomebase-ready.service' \$CTL_LOG"
check "the kiosk gets an invisible pointer: the cursor theme is in its environment, and the theme has a picture under the usual names" "grep -Fxq 'Environment=XCURSOR_PATH=$INST/cursors XCURSOR_THEME=famhomebase-blank XCURSOR_SIZE=24' $KU && [ -e $INST/cursors/famhomebase-blank/cursors/default ] && [ -e $INST/cursors/famhomebase-blank/cursors/text ] && [ \"\$(readlink $INST/cursors/famhomebase-blank/cursors/watch)\" = left_ptr ]"
fresh; setup
check "no splash without --kiosk" "! grep -q '^splash' \$CTL_LOG && [ ! -e $UNIT/famhomebase-splash.path ]"
fresh; FAIL_SPLASH=1 setup --kiosk; st=$?
check "a splash that cannot be set up is a warning, and the kiosk is still set up" "[ $st = 0 ] && grep -q 'boot splash could not be set up' \$WORK/out && [ -f $KU ]"
fresh; rm -f "$INST/splash.sh"; setup --kiosk; st=$?
check "a release without the splash script (an old payload) just has no splash" "[ $st = 0 ] && [ -f $KU ] && [ ! -e $UNIT/famhomebase-splash.path ]"

# a user that exists already (made by an earlier run) is checked for its groups
printf '#!/bin/sh\ncase "$*" in "-nG famhomebase-kiosk") echo famhomebase-kiosk ;; "famhomebase-kiosk") exit 0 ;; "-u famhomebase-kiosk") echo 999 ;; *) exec /usr/bin/id "$@" ;; esac\n' > "$WORK/bin/id"; chmod +x "$WORK/bin/id"
fresh; setup --kiosk
check "a service user that already exists is not made again, and is given the groups it lacks" "! grep -q '^useradd' \$CTL_LOG && grep -q '^usermod -aG video famhomebase-kiosk' \$CTL_LOG && grep -q '^usermod -aG input famhomebase-kiosk' \$CTL_LOG"
rm -f "$WORK/bin/id"
fresh; PATH="$MINPATH" setup --kiosk
check "missing packages: the package lists are refreshed first (a freshly flashed card has none), then it installs" "[ \"\$(grep -n '^apt-get update' \$CTL_LOG | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '^apt-get install' \$CTL_LOG | head -1 | cut -d: -f1)\" ]"
fresh; mkdir -p "$(dirname "$OLD")" "$STATE"; printf '[Service]\nExecStart=x\n' > "$OLD"; setup --kiosk --user tester
check "the old kiosk is stopped before the profile is handed to the new user, and its process is ended if systemd cannot stop it" "[ \"\$(grep -n 'user: systemctl --user disable --now famhomebase-kiosk' \$CTL_LOG | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '^chown -R' \$CTL_LOG | head -1 | cut -d: -f1)\" ] && grep -q '^pkill -u' \$CTL_LOG"
fresh; mkdir -p "$STATE"; echo sum > "$STATE/host-applied"; setup --update
check "a leftover note of an earlier kiosk alone does not turn a plain install into a kiosk (nothing to move, no unit, no packages, no target change)" "[ ! -e $KU ] && ! grep -q 'apt-get\\|useradd\\|set-default' \$CTL_LOG"
fresh; setup --kiosk; DESKTOP_UP=1 setup --update
check "an update that moves a desktop kiosk stops the running desktop too, and restarts the kiosk so it gets the screen" "grep -q 'system: stop display-manager' \$CTL_LOG && grep -q 'system: restart famhomebase-kiosk' \$CTL_LOG"

# updates
fresh; setup --kiosk; : > "$CTL_LOG"; setup --kiosk --update
check "an update that changes nothing does not restart the kiosk, but restarts the display" "! grep -q 'restart famhomebase-kiosk' \$CTL_LOG && grep -q 'system: restart famhomebase.service' \$CTL_LOG"
fresh; setup --kiosk; : > "$CTL_LOG"; setup --update
check "an update (no --kiosk: the unit already exists and is ours) still handles the kiosk" "[ -f $KU ] && grep -q 'system: enable famhomebase-kiosk.service' \$CTL_LOG"
echo '# changed' >> "$INST/kiosk.sh"; : > "$CTL_LOG"; setup --update
check "an update that changes the kiosk script restarts the kiosk" "grep -q 'system: restart famhomebase-kiosk.service' \$CTL_LOG"
: > "$CTL_LOG"; setup --update
check "and not again the next time" "! grep -q 'restart famhomebase-kiosk' \$CTL_LOG"
fresh; setup --kiosk
check "a fresh --kiosk install starts the kiosk once, without restarting it straight away" "grep -q 'system: start famhomebase-kiosk.service' \$CTL_LOG && ! grep -q 'system: restart famhomebase-kiosk' \$CTL_LOG"
fresh; setup --kiosk; echo '# new script' >> "$INST/kiosk.sh"; : > "$CTL_LOG"; ACTIVE=1 setup --kiosk
check "installing over a running kiosk with a changed script restarts it" "grep -q 'system: restart famhomebase-kiosk.service' \$CTL_LOG"
fresh; setup --kiosk; sed -i 's/^Restart=always/Restart=on-failure/' "$KU"; setup --update
check "a unit changed by hand is put back by the next update" "grep -q '^Restart=always' $KU"

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
check "--no-start enables but starts nothing" "! grep -q 'system: start famhomebase' \$CTL_LOG && grep -q 'enable famhomebase.service' \$CTL_LOG && grep -q 'enable famhomebase-kiosk.service' \$CTL_LOG"

fresh; FAIL_RELOAD=1 setup; st=$?
check "no reachable systemd is a warning, not a failure" "[ $st = 0 ] && grep -q '\"level\":\"warn\"' \$WORK/out"

fresh; mkdir -p "$WORK/net/wlan0"; setup
check "turns off Wi-Fi power saving on a Pi with Wi-Fi" "grep -q 'wifi.powersave = 2' $WORK/nm/wifi-powersave.conf"
printf '[connection]\nwifi.powersave = 3\n' > "$WORK/nm/wifi-powersave.conf"; setup
check "and keeps a setting of the owner's own" "grep -q 'powersave = 3' $WORK/nm/wifi-powersave.conf"
fresh; setup
check "no Wi-Fi, no file" "[ ! -e $WORK/nm/wifi-powersave.conf ]"

fresh; setup > /dev/null; cp -r "$UNIT" "$WORK/system.1"; setup
check "running it twice changes nothing" "diff -r $UNIT $WORK/system.1 > /dev/null"
fresh; setup --kiosk > /dev/null; cp -r "$UNIT" "$WORK/system.2"; setup --kiosk
check "with the kiosk too" "diff -r $UNIT $WORK/system.2 > /dev/null"
fresh; setup --bogus; st=$?
check "an unknown option is refused" "[ $st = 2 ]"
check "its log lines are JSON" "grep -q '^{\"ts\":' \$WORK/out || grep -q '^{\"ts\":' \$WORK/err"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
