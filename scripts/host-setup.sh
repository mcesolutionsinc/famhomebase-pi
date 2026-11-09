#!/bin/sh
# The host side of the FamHomeBase display: everything that lives outside the container. Run as root (it asks sudo to run it
# again if it isn't) by the installer, and by the update script after it swaps in new files. Safe to run any number of times.
#
#   host-setup.sh [--kiosk] [--no-start] [--update] [--user NAME]
#     --kiosk      this Pi shows the display full-screen at boot, with no desktop: installs `cage` and the browser if they are
#                  missing, makes the service user, and starts the kiosk service on the screen
#     --no-start   set everything up, but don't start or restart anything
#     --update     the run the update script does after swapping files: restarts the display, and the kiosk if its files changed
#     --user NAME  an earlier install ran the kiosk in this user's desktop (default: the user who ran sudo): that old service is removed
#
# It writes three system units (the display container, the update service and its timer) and, for a kiosk, a fourth: the kiosk. The
# kiosk is `cage` (a compositor that shows one program, full screen, and nothing else) running kiosk.sh as its own service user,
# `famhomebase-kiosk`, on the first virtual terminal. There is no desktop and no login manager, so nothing to log in to and nothing
# that can appear over the display. It also makes the state folder and the `famhomebase` command.
#
# This script lives in /usr/local/lib/famhomebase (its own folder is the install). Settings are in /etc/famhomebase/famhomebase.env,
# state (the saved copy for a way back, the kiosk's browser profile) in /var/lib/famhomebase. The tests move all of them.
set -u

LIB=$(cd "$(dirname "$0")" && pwd)
ETC_DIR=${FAMHOMEBASE_ETC_DIR:-/etc/famhomebase}
STATE_DIR=${FAMHOMEBASE_STATE_DIR:-/var/lib/famhomebase}
BIN_DIR=${FAMHOMEBASE_BIN_DIR:-/usr/local/bin}
ENV_FILE="$ETC_DIR/famhomebase.env"
SYSTEMCTL=${SYSTEMCTL:-systemctl}
RUNUSER=${RUNUSER:-runuser}
APT_GET=${APT_GET:-apt-get}
USERADD=${USERADD:-useradd}
USERMOD=${USERMOD:-usermod}
CHOWN=${CHOWN:-chown}
SYSTEMD_DIR=${FAMHOMEBASE_SYSTEMD_DIR:-/etc/systemd/system}
NM_DIR=${FAMHOMEBASE_NM_CONF_DIR:-/etc/NetworkManager/conf.d} # (the tests point these at a scratch folder)
NET_DIR=${FAMHOMEBASE_NET_DIR:-/sys/class/net}
POLICY_DIRS=${FAMHOMEBASE_CHROMIUM_POLICY_DIRS:-/etc/chromium/policies/managed /etc/chromium-browser/policies/managed} # (older Raspberry Pi OS: chromium-browser)
KIOSK_USER=famhomebase-kiosk

jlog() { printf '{"ts":"%s","level":"%s","component":"host-setup","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | tr '"\\' "'/")"; }

ARGS="$*" # as given, for running again under sudo (the loop below uses them up)
KIOSK=0; START=1; UPDATE=0; USER_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kiosk) KIOSK=1 ;;
    --no-start) START=0 ;;
    --update) UPDATE=1 ;;
    --user) [ $# -ge 2 ] || { jlog error "--user needs a name"; exit 2; }; USER_NAME=$2; shift ;;
    *) jlog error "unknown option $1"; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ] && [ -z "${FAMHOMEBASE_NO_ROOT:-}" ]; then
  # keep the caller's name: after sudo, "who runs this" is root
  [ -n "$USER_NAME" ] || USER_NAME=$(id -un)
  # shellcheck disable=SC2086 # a short list of flags and one name
  exec sudo sh "$0" $ARGS --user "$USER_NAME"
fi

[ -n "$USER_NAME" ] || USER_NAME=${SUDO_USER:-}
USER_HOME=""
if [ -n "$USER_NAME" ] && [ "$USER_NAME" != root ]; then
  USER_HOME=${FAMHOMEBASE_USER_HOME:-$(getent passwd "$USER_NAME" | cut -d: -f6)}
fi
# a value as written in the settings file: a Windows line ending and one pair of quotes around it are not part of it
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -e "s/^\"\\(.*\\)\"\$/\\1/" -e "s/^'\\(.*\\)'\$/\\1/"; }

changed_units=0
write_unit() { # file path, then the file's text on stdin; notes whether it changed
  mkdir -p "$(dirname "$1")"
  cat > "$1.new"
  if cmp -s "$1.new" "$1" 2>/dev/null; then rm -f "$1.new"; else mv "$1.new" "$1"; changed_units=1; fi
}

# --- the state folder and the `famhomebase` command --------------------------------------------------------------------------------------
mkdir -p "$STATE_DIR" "$BIN_DIR" 2>/dev/null
if [ -f "$LIB/famhomebase" ]; then ln -sf "$LIB/famhomebase" "$BIN_DIR/famhomebase" 2>/dev/null || jlog warn "could not make the famhomebase command in $BIN_DIR"; fi

# --- Wi-Fi power saving makes the Pi's connection lag and drop. Written once, never overwritten, so a setting of your own is kept. ----
nm_conf="$NM_DIR/wifi-powersave.conf"
if [ -d "$NM_DIR" ] && [ -e "$NET_DIR/wlan0" ] && [ ! -e "$nm_conf" ]; then
  if printf '[connection]\nwifi.powersave = 2\n' > "$nm_conf" 2>/dev/null; then
    jlog info "turned off Wi-Fi power saving (applies after the next reboot)"
  else
    jlog warn "could not turn off Wi-Fi power saving"
  fi
fi

# --- an earlier install of this display (named "cloud", before 0.2.0) has its own units, which would fight this one for the container name and the port ---
for old in famhomebase-cloud.service famhomebase-cloud-update.timer famhomebase-cloud-update.service; do
  if [ -f "$SYSTEMD_DIR/$old" ]; then
    "$SYSTEMCTL" disable --now "$old" >/dev/null 2>&1
    rm -f "$SYSTEMD_DIR/$old"
    jlog info "removed the older unit $old (this install replaces it; the old folder can be deleted)"
    changed_units=1
  fi
done

# --- the system units --------------------------------------------------------------------------------------------------------------
hours=$(getenv CHECK_INTERVAL_HOURS)
case "$hours" in ''|*[!0-9]*) hours=6 ;; esac
{ [ "$hours" -ge 1 ] && [ "$hours" -le 168 ]; } || hours=6

write_unit "$SYSTEMD_DIR/famhomebase.service" <<UNIT_EOF
[Unit]
Description=FamHomeBase display (container)
Requires=docker.service
After=docker.service

[Service]
ExecStart=/bin/sh "$LIB/run.sh"
ExecStopPost=-/bin/sh -c 'docker rm -f famhomebase-display >/dev/null 2>&1'
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT_EOF

write_unit "$SYSTEMD_DIR/famhomebase-update.service" <<UNIT_EOF
[Unit]
Description=FamHomeBase: look for an update and apply it
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh "$LIB/update.sh"
UNIT_EOF

write_unit "$SYSTEMD_DIR/famhomebase-update.timer" <<UNIT_EOF
[Unit]
Description=FamHomeBase: look for an update every $hours hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=${hours}h
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
UNIT_EOF

# --- the kiosk: cage and the browser, a system service of its own user, on the first virtual terminal ----------------------------------------
kiosk_unit="$SYSTEMD_DIR/famhomebase-kiosk.service"

# An install before 0.4.0 ran its kiosk in a user's desktop (a user service). Find those: the user named (or who ran sudo), and, for an
# update, which has neither, every home folder.
homes=""
[ -n "$USER_HOME" ] && homes="$USER_HOME"
for h in ${FAMHOMEBASE_HOMES:-/home/*}; do [ "$h" = "$USER_HOME" ] || homes="$homes $h"; done
old_units=""
for h in $homes; do [ -f "$h/.config/systemd/user/famhomebase-kiosk.service" ] && old_units="$old_units $h/.config/systemd/user/famhomebase-kiosk.service"; done

# a kiosk if asked for, or if this install already is one: its unit is here, or an old desktop kiosk of this display is there to move
kiosk=0
if [ "$KIOSK" -eq 1 ] || { [ -f "$kiosk_unit" ] && grep -Fq "$LIB/kiosk.sh" "$kiosk_unit"; } || { [ -n "$old_units" ] && [ -f "$STATE_DIR/host-applied" ]; }; then kiosk=1; fi

# With the new kiosk in charge the old one would fight it for the screen: stop it first (before anything below changes who owns the
# browser's profile), and remove it. If its user's systemd cannot be reached the process is ended directly.
if [ "$kiosk" -eq 1 ]; then
  for old in $old_units; do
    who=$(stat -c %U "$old" 2>/dev/null || echo "$USER_NAME")
    uid=$(id -u "$who" 2>/dev/null || echo 0)
    for u in famhomebase-kiosk.service famhomebase-host.path; do
      "$RUNUSER" -u "$who" -- env "XDG_RUNTIME_DIR=/run/user/$uid" "$SYSTEMCTL" --user disable --now "$u" >/dev/null 2>&1 || true
    done
    pkill -u "$who" -f '/famhomebase/(scripts/)?kiosk\.sh' >/dev/null 2>&1 || true
    rm -f "$old"
    jlog info "removed the old desktop kiosk service of $who (the kiosk is a system service now)"
  done
fi

kiosk_changed=0
if [ "$kiosk" -eq 1 ]; then
  # what it needs: cage and a browser (Raspberry Pi OS Lite has neither). The package lists of a freshly flashed card can be empty.
  apt_updated=0
  need_pkg() { # command, package
    command -v "$1" >/dev/null 2>&1 && return 0
    jlog info "installing $2 (the kiosk needs it)"
    if [ "$apt_updated" -eq 0 ]; then DEBIAN_FRONTEND=noninteractive "$APT_GET" update -q >/dev/null 2>&1 || true; apt_updated=1; fi
    DEBIAN_FRONTEND=noninteractive "$APT_GET" install -y -q "$2" >/dev/null 2>&1 || { jlog warn "could not install $2: install it by hand (sudo apt install $2), then restart famhomebase-kiosk"; return 1; }
  }
  need_pkg cage cage
  need_pkg swayimg swayimg # shows the logo picture while the browser starts (kiosk.sh); a kiosk without it just has a black screen a little longer
  command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 || need_pkg chromium chromium

  # its own user: no password, no shell, no login. It may use the screen and the keyboard and mouse. A user that exists is checked for
  # the groups too (one made by a run that failed half way, or before a group existed).
  groups=""
  for g in video render input; do getent group "$g" >/dev/null 2>&1 && groups="$groups $g"; done
  if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    # shellcheck disable=SC2086 # a short list of group names
    "$USERADD" --system --home-dir "$STATE_DIR/kiosk-home" --create-home --shell /usr/sbin/nologin ${groups:+--groups "$(echo $groups | tr ' ' ',')"} "$KIOSK_USER" >/dev/null 2>&1 \
      || jlog warn "could not make the user $KIOSK_USER: the kiosk cannot start"
  else
    for g in $groups; do id -nG "$KIOSK_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$g" || "$USERMOD" -aG "$g" "$KIOSK_USER" >/dev/null 2>&1 || jlog warn "could not add $KIOSK_USER to the group $g"; done
  fi
  # its browser profile (it holds the pairing) is its own. Done on every run, so a profile left to another user (an earlier desktop
  # kiosk) or made by root is put right.
  mkdir -p "$STATE_DIR/kiosk-profile" "$STATE_DIR/kiosk-home" 2>/dev/null
  "$CHOWN" -R "$KIOSK_USER" "$STATE_DIR/kiosk-profile" "$STATE_DIR/kiosk-home" 2>/dev/null || jlog warn "could not hand the kiosk's profile folder to $KIOSK_USER"

  before=$(cksum < "$kiosk_unit" 2>/dev/null || true)
  write_unit "$kiosk_unit" <<UNIT_EOF
[Unit]
Description=FamHomeBase kiosk display (cage, then the browser)
After=systemd-user-sessions.service famhomebase.service famhomebase-ready.service getty@tty1.service plymouth-quit.service plymouth-quit-wait.service
Wants=famhomebase.service
Conflicts=getty@tty1.service

[Service]
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpMode=user
# an invisible pointer (the screen is not touched or pointed at): cage and the browser both read the cursor theme from here
Environment=XCURSOR_PATH=$LIB/cursors XCURSOR_THEME=famhomebase-blank XCURSOR_SIZE=24
# the screen is only usable by a session on the terminal that is in front: bring terminal 1 forward (a desktop may have left 7 there)
ExecStartPre=-+/usr/bin/chvt 1
# the text cursor of that terminal shows on the black screen between the splash and the browser: switch it off
ExecStartPre=-+/bin/sh -c 'printf "\\033[?25l\\033[?1c" > /dev/tty1'
ExecStart=/usr/bin/cage -- "$LIB/kiosk.sh"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
  [ "$before" != "$(cksum < "$kiosk_unit" 2>/dev/null || true)" ] && kiosk_changed=1

  # the pointer's invisible cursor theme: one transparent picture under every name a program may ask for
  cursors="$LIB/cursors/famhomebase-blank/cursors"
  if [ -f "$cursors/left_ptr" ]; then
    # cage (the screen service) draws a pointer of its own from the theme called "default", whatever XCURSOR_THEME says, so that name is the
    # blank theme too (without this an arrow showed in the middle of the screen from the splash until the browser opened)
    ln -sfn famhomebase-blank "$LIB/cursors/default" 2>/dev/null
    for name in default arrow pointer text xterm hand hand1 hand2 grab grabbing crosshair watch wait progress move help not-allowed; do ln -sf left_ptr "$cursors/$name" 2>/dev/null; done
  fi

  # reads the browser's files into the file cache during the boot, at the lowest priority (warm.sh): the browser then starts about 6 s sooner
  if [ -f "$LIB/warm.sh" ]; then
    write_unit "$SYSTEMD_DIR/famhomebase-warm.service" <<UNIT_EOF
[Unit]
Description=FamHomeBase: read the browser's files into memory so the display starts sooner

[Service]
Type=simple
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
ExecStart=/bin/sh "$LIB/warm.sh"

[Install]
WantedBy=multi-user.target
UNIT_EOF
  fi

  # the browser's own window is drawn white or grey for a moment before the page paints: a browser policy gives that window the page's
  # dark colour. Debian's Chromium reads every file in this folder, and the policy changes nothing else about it.
  for dir in $POLICY_DIRS; do
    mkdir -p "$dir" 2>/dev/null
    printf '{ "BrowserThemeColor": "#0A1327" }\n' > "$dir/famhomebase.json" 2>/dev/null || jlog warn "could not write the browser's colour policy to $dir"
  done

  # the boot splash (logo and moving dots, turned for how the screen is mounted): the packages, the quiet boot settings and the theme, and
  # a unit that makes the theme again when the page tells the host a new rotation
  if [ -f "$LIB/splash.sh" ]; then
    sh "$LIB/splash.sh" install || jlog warn "the boot splash could not be set up: see the lines above"
    write_unit "$SYSTEMD_DIR/famhomebase-splash.service" <<UNIT_EOF
[Unit]
Description=FamHomeBase: make the boot splash for the screen's rotation

[Service]
Type=oneshot
ExecStart=/bin/sh "$LIB/splash.sh" apply
UNIT_EOF
    write_unit "$SYSTEMD_DIR/famhomebase-splash.path" <<UNIT_EOF
[Unit]
Description=FamHomeBase: the screen's rotation was written

[Path]
PathChanged=$STATE_DIR/state/rotation
Unit=famhomebase-splash.service

[Install]
WantedBy=multi-user.target
UNIT_EOF
    # plymouth (the splash) leaves only when the page is being served, so the splash covers the wait instead of a blank screen, and then keeps
    # its last picture on the screen when it leaves (the kiosk starts right after) instead of blanking it
    write_unit "$SYSTEMD_DIR/famhomebase-ready.service" <<UNIT_EOF
[Unit]
Description=FamHomeBase: wait until the display's page is being served
After=famhomebase.service
Wants=famhomebase.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh "$LIB/ready.sh"

[Install]
WantedBy=multi-user.target
UNIT_EOF
    write_unit "$SYSTEMD_DIR/plymouth-quit.service.d/famhomebase.conf" <<UNIT_EOF
[Unit]
After=famhomebase-ready.service
Wants=famhomebase-ready.service

[Service]
ExecStart=
ExecStart=-/usr/bin/plymouth quit --retain-splash
UNIT_EOF
    # cloud-init prints a line ("Completed socket interaction for boot stage final") on the screen right after the splash leaves, which
    # showed on a black screen for seconds on the first real Pi. Its output stays in the journal.
    for svc in cloud-init-local cloud-init-network cloud-config cloud-final; do
      write_unit "$SYSTEMD_DIR/$svc.service.d/famhomebase-quiet.conf" <<UNIT_EOF
[Service]
StandardOutput=journal
StandardError=journal
UNIT_EOF
    done
  fi
fi

# --- enable and start ---------------------------------------------------------------------------------------------------------------
if "$SYSTEMCTL" daemon-reload >/dev/null 2>&1; then
  "$SYSTEMCTL" enable docker.service >/dev/null 2>&1 || true
  "$SYSTEMCTL" enable famhomebase.service famhomebase-update.timer >/dev/null 2>&1
  if [ "$kiosk" -eq 1 ]; then
    "$SYSTEMCTL" enable famhomebase-kiosk.service >/dev/null 2>&1
    [ -f "$SYSTEMD_DIR/famhomebase-splash.path" ] && "$SYSTEMCTL" enable famhomebase-splash.path famhomebase-ready.service >/dev/null 2>&1
    [ -f "$SYSTEMD_DIR/famhomebase-warm.service" ] && "$SYSTEMCTL" enable famhomebase-warm.service >/dev/null 2>&1
    # no desktop: boot to the text target, so no login manager starts and takes the screen
    [ "$("$SYSTEMCTL" get-default 2>/dev/null)" = graphical.target ] && "$SYSTEMCTL" set-default multi-user.target >/dev/null 2>&1
  fi
  if [ "$START" -eq 1 ]; then
    "$SYSTEMCTL" start famhomebase-update.timer >/dev/null 2>&1
    if [ "$kiosk" -eq 1 ] && [ -f "$SYSTEMD_DIR/famhomebase-splash.path" ]; then
      # a changed unit needs the running watch restarted, or it keeps the old one until the next boot
      if [ "$changed_units" -eq 1 ]; then "$SYSTEMCTL" restart famhomebase-splash.path >/dev/null 2>&1; else "$SYSTEMCTL" start famhomebase-splash.path >/dev/null 2>&1; fi
    fi
    if [ "$UPDATE" -eq 1 ]; then
      "$SYSTEMCTL" restart famhomebase.service >/dev/null 2>&1 && jlog info "restarted the display"
      [ "$changed_units" -eq 1 ] && "$SYSTEMCTL" restart famhomebase-update.timer >/dev/null 2>&1
    else
      # an install over a running one (new units, new settings) restarts it, so it runs what was just written
      if "$SYSTEMCTL" is-active --quiet famhomebase.service >/dev/null 2>&1; then
        "$SYSTEMCTL" restart famhomebase.service >/dev/null 2>&1 || jlog warn "could not restart the display: see journalctl -u famhomebase"
      else
        "$SYSTEMCTL" start famhomebase.service >/dev/null 2>&1 || jlog warn "could not start the display: see journalctl -u famhomebase"
      fi
    fi
    if [ "$kiosk" -eq 1 ]; then
      # the kiosk script is read when the service starts, so a changed script needs a restart to take effect
      state="$STATE_DIR/host-applied"
      scripts_now=$(cat "$LIB/kiosk.sh" 2>/dev/null | cksum)
      scripts_before=$(cat "$state" 2>/dev/null || true)
      # a desktop that is up would hold the screen: stop it (it does not come back at the next boot)
      if "$SYSTEMCTL" is-active --quiet display-manager.service >/dev/null 2>&1; then
        "$SYSTEMCTL" stop display-manager.service >/dev/null 2>&1
        kiosk_changed=1 # a kiosk that started while it was up never got the screen
      fi
      if [ "$UPDATE" -eq 1 ]; then
        if [ "$scripts_now" != "$scripts_before" ] || [ "$kiosk_changed" -eq 1 ]; then
          "$SYSTEMCTL" restart famhomebase-kiosk.service >/dev/null 2>&1 && jlog info "restarted the kiosk"
        fi
      else
        was_active=0; "$SYSTEMCTL" is-active --quiet famhomebase-kiosk.service >/dev/null 2>&1 && was_active=1
        "$SYSTEMCTL" start famhomebase-kiosk.service >/dev/null 2>&1 || jlog warn "could not start the kiosk: see journalctl -u famhomebase-kiosk"
        # already running on an older script or unit: move it onto this install's
        if [ "$was_active" -eq 1 ] && { [ "$kiosk_changed" -eq 1 ] || [ "$scripts_now" != "$scripts_before" ]; }; then
          "$SYSTEMCTL" restart famhomebase-kiosk.service >/dev/null 2>&1
        fi
      fi
      printf '%s\n' "$scripts_now" > "$state" 2>/dev/null || true
    fi
  fi
else
  jlog warn "could not reach systemd: the display starts at the next boot, or run: systemctl enable --now famhomebase.service famhomebase-update.timer"
fi
exit 0
