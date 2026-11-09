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
CHOWN=${CHOWN:-chown}
SYSTEMD_DIR=${FAMHOMEBASE_SYSTEMD_DIR:-/etc/systemd/system}
NM_DIR=${FAMHOMEBASE_NM_CONF_DIR:-/etc/NetworkManager/conf.d} # (the tests point these at a scratch folder)
NET_DIR=${FAMHOMEBASE_NET_DIR:-/sys/class/net}
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
After=docker.service network-online.target
Wants=network-online.target

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
kiosk=0
# a kiosk if asked for, or if this install already is one: its unit is here, or (an install before 0.4.0, which ran in a desktop) the
# note an earlier kiosk setup left
if [ "$KIOSK" -eq 1 ] || { [ -f "$kiosk_unit" ] && grep -Fq "$LIB/kiosk.sh" "$kiosk_unit"; } || [ -f "$STATE_DIR/host-applied" ]; then kiosk=1; fi
kiosk_changed=0
if [ "$kiosk" -eq 1 ]; then
  # what it needs: cage and a browser (Raspberry Pi OS Lite has neither)
  need_pkg() { # command, package
    command -v "$1" >/dev/null 2>&1 && return 0
    jlog info "installing $2 (the kiosk needs it)"
    "$APT_GET" install -y -q "$2" >/dev/null 2>&1 || { jlog warn "could not install $2: install it by hand (sudo apt install $2), then restart famhomebase-kiosk"; return 1; }
  }
  need_pkg cage cage
  command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 || need_pkg chromium chromium

  # its own user: no password, no shell, no login. It may use the screen and the keyboard and mouse.
  if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    groups=""
    for g in video render input; do getent group "$g" >/dev/null 2>&1 && groups="$groups,$g"; done
    "$USERADD" --system --home-dir "$STATE_DIR/kiosk-home" --create-home --shell /usr/sbin/nologin ${groups:+--groups "${groups#,}"} "$KIOSK_USER" >/dev/null 2>&1 \
      || jlog warn "could not make the user $KIOSK_USER: the kiosk cannot start"
  fi
  # its browser profile (it holds the pairing) is its own. Done on every run, so a profile left to another user (an earlier desktop
  # kiosk) or made by root is put right.
  mkdir -p "$STATE_DIR/kiosk-profile" "$STATE_DIR/kiosk-home" 2>/dev/null
  "$CHOWN" -R "$KIOSK_USER" "$STATE_DIR/kiosk-profile" "$STATE_DIR/kiosk-home" 2>/dev/null || jlog warn "could not hand the kiosk's profile folder to $KIOSK_USER"

  before=$(cksum < "$kiosk_unit" 2>/dev/null || true)
  write_unit "$kiosk_unit" <<UNIT_EOF
[Unit]
Description=FamHomeBase kiosk display (cage, then the browser)
After=systemd-user-sessions.service famhomebase.service getty@tty1.service
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
# the screen is only usable by a session on the terminal that is in front: bring terminal 1 forward (a desktop may have left 7 there)
ExecStartPre=-+/usr/bin/chvt 1
ExecStart=/usr/bin/cage -- "$LIB/kiosk.sh"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
  [ "$before" != "$(cksum < "$kiosk_unit" 2>/dev/null || true)" ] && kiosk_changed=1
fi

# the kiosk of an earlier install ran in a user's desktop (a user service). With this one in charge it would fight it for the screen.
# The user is the one named (or who ran sudo); an update, which has neither, looks in every home folder.
if [ "$kiosk" -eq 1 ]; then
  homes=""
  [ -n "$USER_HOME" ] && homes="$USER_HOME"
  for h in ${FAMHOMEBASE_HOMES:-/home/*}; do [ "$h" = "$USER_HOME" ] || homes="$homes $h"; done
  for h in $homes; do
    old="$h/.config/systemd/user/famhomebase-kiosk.service"
    [ -f "$old" ] || continue
    who=$(stat -c %U "$old" 2>/dev/null || echo "$USER_NAME")
    "$RUNUSER" -u "$who" -- env "XDG_RUNTIME_DIR=/run/user/$(id -u "$who" 2>/dev/null || echo 0)" "$SYSTEMCTL" --user disable --now famhomebase-kiosk.service >/dev/null 2>&1
    "$RUNUSER" -u "$who" -- env "XDG_RUNTIME_DIR=/run/user/$(id -u "$who" 2>/dev/null || echo 0)" "$SYSTEMCTL" --user disable --now famhomebase-host.path >/dev/null 2>&1
    rm -f "$old"
    jlog info "removed the old desktop kiosk service of $who (the kiosk is a system service now)"
  done
fi

# --- enable and start ---------------------------------------------------------------------------------------------------------------
if "$SYSTEMCTL" daemon-reload >/dev/null 2>&1; then
  "$SYSTEMCTL" enable docker.service >/dev/null 2>&1 || true
  "$SYSTEMCTL" enable famhomebase.service famhomebase-update.timer >/dev/null 2>&1
  if [ "$kiosk" -eq 1 ]; then
    "$SYSTEMCTL" enable famhomebase-kiosk.service >/dev/null 2>&1
    # no desktop: boot to the text target, so no login manager starts and takes the screen
    [ "$("$SYSTEMCTL" get-default 2>/dev/null)" = graphical.target ] && "$SYSTEMCTL" set-default multi-user.target >/dev/null 2>&1
  fi
  if [ "$START" -eq 1 ]; then
    "$SYSTEMCTL" start famhomebase-update.timer >/dev/null 2>&1
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
      if [ "$UPDATE" -eq 1 ]; then
        if [ "$scripts_now" != "$scripts_before" ] || [ "$kiosk_changed" -eq 1 ]; then
          "$SYSTEMCTL" restart famhomebase-kiosk.service >/dev/null 2>&1 && jlog info "restarted the kiosk"
        fi
      else
        # a desktop that is up would hold the screen: stop it (it does not come back at the next boot)
        "$SYSTEMCTL" is-active --quiet display-manager.service >/dev/null 2>&1 && "$SYSTEMCTL" stop display-manager.service >/dev/null 2>&1
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
