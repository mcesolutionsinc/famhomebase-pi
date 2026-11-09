#!/bin/sh
# The host side of the FamHomeBase display: everything that lives outside the container. Run as root (it asks sudo to run it
# again if it isn't) by the installer, and by the update script after it swaps in new files. Safe to run any number of times.
#
#   host-setup.sh [--kiosk] [--no-start] [--update] [--user NAME]
#     --kiosk      this Pi shows the display full-screen at boot (also turns on desktop autologin, and takes over the kiosk
#                  service even if an older FamHomeBase install owns it)
#     --no-start   set everything up, but don't start or restart anything
#     --update     the run the update script does after swapping files: restarts the display, and the kiosk if its files changed
#     --user NAME  whose desktop the kiosk runs in (default: the owner of this folder)
#
# It writes three system units (the display container, the update service and its timer) and, for a kiosk, one user unit that runs
# scripts/kiosk.sh. Without --kiosk it leaves a kiosk service that points at another install alone, so a test install can sit beside
# a working one.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
DIR=$(cd "$HERE/.." && pwd)
SYSTEMCTL=${SYSTEMCTL:-systemctl}
RUNUSER=${RUNUSER:-runuser}
SYSTEMD_DIR=${FAMHOMEBASE_SYSTEMD_DIR:-/etc/systemd/system}
NM_DIR=${FAMHOMEBASE_NM_CONF_DIR:-/etc/NetworkManager/conf.d} # (the tests point these at a scratch folder)
NET_DIR=${FAMHOMEBASE_NET_DIR:-/sys/class/net}

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
  # keep the caller's name for the kiosk: after sudo, "who runs this" is root
  [ -n "$USER_NAME" ] || USER_NAME=$(id -un)
  # shellcheck disable=SC2086 # a short list of flags and one name
  exec sudo sh "$0" $ARGS --user "$USER_NAME"
fi

[ -n "$USER_NAME" ] || USER_NAME=$(stat -c %U "$DIR" 2>/dev/null || echo root)
USER_HOME=${FAMHOMEBASE_USER_HOME:-$(getent passwd "$USER_NAME" | cut -d: -f6)}
USER_ID=$(id -u "$USER_NAME" 2>/dev/null || echo 0)
# a value as written in .env: a Windows line ending and one pair of quotes around it are not part of it
getenv() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$DIR/.env" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -e "s/^\"\\(.*\\)\"\$/\\1/" -e "s/^'\\(.*\\)'\$/\\1/"; }

changed_units=0
write_unit() { # file path, then the file's text on stdin; notes whether it changed
  case "$1" in
    "$USER_HOME"/*) # a file in the user's home: any folder made on the way belongs to the user, not to root
      d="$USER_HOME"
      for part in $(dirname "${1#"$USER_HOME"/}" | tr '/' ' '); do
        d="$d/$part"
        [ -d "$d" ] || { mkdir "$d" && chown "$USER_NAME" "$d" 2>/dev/null; }
      done ;;
    *) mkdir -p "$(dirname "$1")" ;;
  esac
  cat > "$1.new"
  if cmp -s "$1.new" "$1" 2>/dev/null; then rm -f "$1.new"; else mv "$1.new" "$1"; changed_units=1; fi
}

# --- the kiosk's desktop session: log in to the desktop by itself ---------------------------------------------------------------------
if [ "$KIOSK" -eq 1 ] && command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_boot_behaviour B4 >/dev/null 2>&1 || jlog warn "could not turn on desktop autologin: do it in raspi-config (System Options, Boot / Auto Login)"
fi

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
ExecStart=/bin/sh "$DIR/scripts/run.sh"
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
ExecStart=/bin/sh "$DIR/scripts/update.sh"
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

# --- the kiosk (a user unit, in the desktop user's own systemd) ----------------------------------------------------------------------
kiosk_unit="$USER_HOME/.config/systemd/user/famhomebase-kiosk.service"
kiosk=0
if [ "$KIOSK" -eq 1 ]; then
  kiosk=1
elif [ -f "$kiosk_unit" ]; then
  if grep -Fxq "ExecStart=\"$DIR/scripts/kiosk.sh\"" "$kiosk_unit"; then
    kiosk=1
  else
    jlog info "left the kiosk service alone: it belongs to another FamHomeBase install (use --kiosk to move it here)"
  fi
fi
kiosk_changed=0
if [ "$kiosk" -eq 1 ]; then
  before=$(cksum < "$kiosk_unit" 2>/dev/null || true)
  write_unit "$kiosk_unit" <<UNIT_EOF
[Unit]
Description=FamHomeBase kiosk display

[Service]
ExecStart="$DIR/scripts/kiosk.sh"
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT_EOF
  chown -R "$USER_NAME" "$USER_HOME/.config/systemd" 2>/dev/null || true
  [ "$before" != "$(cksum < "$kiosk_unit" 2>/dev/null || true)" ] && kiosk_changed=1
fi

# --- enable and start ---------------------------------------------------------------------------------------------------------------
user_ctl() { "$RUNUSER" -u "$USER_NAME" -- env "XDG_RUNTIME_DIR=/run/user/$USER_ID" "$SYSTEMCTL" --user "$@"; }

if "$SYSTEMCTL" daemon-reload >/dev/null 2>&1; then
  "$SYSTEMCTL" enable docker.service >/dev/null 2>&1 || true
  "$SYSTEMCTL" enable famhomebase.service famhomebase-update.timer >/dev/null 2>&1
  if [ "$START" -eq 1 ]; then
    "$SYSTEMCTL" start famhomebase-update.timer >/dev/null 2>&1
    if [ "$UPDATE" -eq 1 ]; then
      "$SYSTEMCTL" restart famhomebase.service >/dev/null 2>&1 && jlog info "restarted the display"
      [ "$changed_units" -eq 1 ] && "$SYSTEMCTL" restart famhomebase-update.timer >/dev/null 2>&1
    else
      "$SYSTEMCTL" start famhomebase.service >/dev/null 2>&1 || jlog warn "could not start the display: see journalctl -u famhomebase"
    fi
  fi
else
  jlog warn "could not reach systemd: the display starts at the next boot, or run: systemctl enable --now famhomebase.service famhomebase-update.timer"
fi

if [ "$kiosk" -eq 1 ]; then
  # the kiosk script is read when the service starts, so a changed script needs a restart to take effect
  state="$DIR/.host-applied"
  scripts_now=$(cat "$DIR/scripts/kiosk.sh" 2>/dev/null | cksum)
  scripts_before=$(cat "$state" 2>/dev/null || true)
  if user_ctl daemon-reload >/dev/null 2>&1; then
    # an earlier line of FamHomeBase re-ran its own host setup from a user path unit; with this install in charge that would undo it
    user_ctl disable --now famhomebase-host.path >/dev/null 2>&1 || true
    if [ "$START" -eq 1 ]; then
      if [ "$UPDATE" -eq 1 ]; then
        if [ "$scripts_now" != "$scripts_before" ] || [ "$kiosk_changed" -eq 1 ]; then
          user_ctl restart famhomebase-kiosk.service >/dev/null 2>&1 && jlog info "restarted the kiosk"
        fi
      else
        was_active=0; user_ctl is-active --quiet famhomebase-kiosk.service >/dev/null 2>&1 && was_active=1
        user_ctl enable --now famhomebase-kiosk.service >/dev/null 2>&1 || jlog warn "could not start the kiosk: it starts at the next login"
        # already running on an older script or unit: move it onto this install's. A kiosk that was not running was just started on the new ones.
        if [ "$was_active" -eq 1 ] && { [ "$kiosk_changed" -eq 1 ] || [ "$scripts_now" != "$scripts_before" ]; }; then
          user_ctl restart famhomebase-kiosk.service >/dev/null 2>&1
        fi
      fi
    else
      user_ctl enable famhomebase-kiosk.service >/dev/null 2>&1
    fi
  else
    jlog warn "could not reach $USER_NAME's systemd (normal before the first desktop login): the kiosk starts at the next login"
  fi
  printf '%s\n' "$scripts_now" > "$state" 2>/dev/null || true
  chown "$USER_NAME" "$state" 2>/dev/null || true
fi
exit 0
