#!/bin/sh
# The host side of FamHomeBase: everything that lives outside the containers — the kiosk service, the display tools, and the
# unit that re-runs this after an update. Two stages, so each does what it is able to:
#   1. The updater (a container) swaps in new files and images. It can't touch the Pi itself.
#   2. This script, run by systemd on the Pi (as you, not root), applies whatever the new files need on the host.
#
#   host-setup.sh [--kiosk] [--no-start] [--update]
#     --kiosk      this Pi shows the dashboard full-screen (also turns on desktop autologin). Without it, the kiosk is set up
#                  only if it already is one (a kiosk service exists, or the old labwc autostart line does).
#     --no-start   set up, but don't start or restart anything
#     --update     the run systemd does after an update: no prompts, and it restarts the kiosk if the scripts changed
#
# Safe to run any number of times. install.sh runs it; so does famhomebase-host.path whenever VERSION changes.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
DIR=$(cd "$HERE/.." && pwd)
KIOSK=0; START=1; UPDATE=0
for arg in "$@"; do
  case "$arg" in
    --kiosk) KIOSK=1 ;;
    --no-start) START=0 ;;
    --update) UPDATE=1 ;;
    *) echo "host-setup: unknown option $arg" >&2; exit 2 ;;
  esac
done
say() { printf '%s\n' "$*"; }

unit_dir="$HOME/.config/systemd/user"
kiosk_unit="$unit_dir/famhomebase-kiosk.service"
autostart="$HOME/.config/labwc/autostart"
legacy=0
{ [ -f "$autostart" ] && grep -q 'kiosk=1' "$autostart"; } && legacy=1

# Not a kiosk (a headless Pi, or a laptop): nothing to do on the host.
if [ "$KIOSK" -eq 0 ] && [ "$legacy" -eq 0 ] && [ ! -f "$kiosk_unit" ]; then exit 0; fi

XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export XDG_RUNTIME_DIR

if [ "$KIOSK" -eq 1 ]; then
  say "Setting this Pi to show the dashboard full-screen at boot..."
  if command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4 || say "  (could not turn on desktop autologin — do it in raspi-config: System Options > Boot / Auto Login)"
  else
    say "  (raspi-config not found — make sure this machine logs into its desktop automatically)"
  fi
fi

# The display tools the kiosk uses: wlr-randr rotates the screen, wlopm turns it off at night (Settings → Night mode).
missing=""
for tool in wlr-randr wlopm; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done
if [ -n "$missing" ]; then
  say "Installing the screen tools:$missing"
  # After an update there is nobody to type a password: sudo -n only succeeds when sudo needs none.
  if [ "$UPDATE" -eq 1 ]; then sudo_cmd="sudo -n"; else sudo_cmd="sudo"; fi
  # shellcheck disable=SC2086 # a list of package names
  $sudo_cmd apt-get install -y $missing >/dev/null 2>&1 || say "  (could not install them — run: sudo apt install$missing)"
fi

# Wi-Fi power saving, which the Pi's wireless chip has on by default, makes the connection drop and lag — the dashboard then loads slowly
# or not at all. Turn it off for a Pi on Wi-Fi. Written once and never overwritten, so a setting of your own is kept; it takes effect
# when the Pi next reconnects or reboots (restarting NetworkManager now would drop the connection in the middle of an update).
nm_dir=${FAMHOMEBASE_NM_CONF_DIR:-/etc/NetworkManager/conf.d} # (the tests point these two at a scratch folder)
net_dir=${FAMHOMEBASE_NET_DIR:-/sys/class/net}
nm_conf="$nm_dir/wifi-powersave.conf"
if [ -d "$nm_dir" ] && [ -e "$net_dir/wlan0" ] && [ ! -e "$nm_conf" ]; then
  say "Turning off Wi-Fi power saving (it makes the Pi's connection lag and drop)..."
  if [ "$UPDATE" -eq 1 ]; then sudo_cmd="sudo -n"; else sudo_cmd="sudo"; fi
  # shellcheck disable=SC2016 # the quotes are for the inner shell
  $sudo_cmd sh -c 'printf "[connection]\nwifi.powersave = 2\n" > "$1"' sh "$nm_conf" >/dev/null 2>&1 \
    && say "  Done; it applies after the next reboot." \
    || say "  (could not — run: sudo sh -c 'printf \"[connection]\\nwifi.powersave = 2\\n\" > $nm_conf')"
fi

mkdir -p "$unit_dir"
write_unit() { # name, then the file's text on stdin; reports whether it changed
  cat > "$unit_dir/$1.new"
  if cmp -s "$unit_dir/$1.new" "$unit_dir/$1" 2>/dev/null; then rm -f "$unit_dir/$1.new"; else mv "$unit_dir/$1.new" "$unit_dir/$1"; changed_units=1; fi
}
changed_units=0

write_unit famhomebase-kiosk.service <<UNIT_EOF
[Unit]
Description=FamHomeBase kiosk display

[Service]
ExecStart=$DIR/scripts/kiosk.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT_EOF

# Stage two of an update: when the updater changes VERSION, systemd runs this script again.
write_unit famhomebase-host.service <<UNIT_EOF
[Unit]
Description=FamHomeBase: apply an update on this Pi

[Service]
Type=oneshot
ExecStart=/bin/sh $DIR/scripts/host-setup.sh --update
UNIT_EOF
write_unit famhomebase-host.path <<UNIT_EOF
[Unit]
Description=FamHomeBase: watch for an update

[Path]
PathChanged=$DIR/VERSION

[Install]
WantedBy=default.target
UNIT_EOF

if [ "$legacy" -eq 1 ]; then
  cp -f "$autostart" "$autostart.bak"
  awk '/kiosk=1/ || /^# Wait for the dashboard to be up, then open it full-screen/ { next } { print }' "$autostart.bak" > "$autostart.new" && cat "$autostart.new" > "$autostart"
  rm -f "$autostart.new"
  say "Moved the kiosk from $autostart to a systemd service (the old file is saved as autostart.bak; your other lines in it stay)."
  pkill -x chromium >/dev/null 2>&1 || true # the old kiosk's browser: the service starts its own
fi

# The kiosk and screen scripts are read when the service starts, so an update that changes them needs a restart to take effect.
state="$DIR/.host-applied"
scripts_now=$(cat "$DIR/scripts/kiosk.sh" "$DIR/scripts/screen.sh" 2>/dev/null | cksum)
scripts_before=$(cat "$state" 2>/dev/null || true)

if systemctl --user daemon-reload >/dev/null 2>&1; then
  systemctl --user enable famhomebase-host.path >/dev/null 2>&1
  if [ "$START" -eq 1 ]; then
    systemctl --user start famhomebase-host.path >/dev/null 2>&1
    if [ "$UPDATE" -eq 1 ]; then
      # Restart only if the scripts changed (or the unit did), so an update that doesn't touch the display doesn't blink it.
      if [ "$scripts_now" != "$scripts_before" ] || [ "$changed_units" -eq 1 ]; then
        systemctl --user restart famhomebase-kiosk.service >/dev/null 2>&1 && say "Restarted the kiosk to use the updated scripts."
      fi
    else
      # Already running on the old scripts: restart it onto the new ones. Not running: enabling it starts it.
      was_active=0; systemctl --user is-active --quiet famhomebase-kiosk.service >/dev/null 2>&1 && was_active=1
      systemctl --user enable --now famhomebase-kiosk.service >/dev/null 2>&1 && say "  The kiosk service is running; restart it any time with: systemctl --user restart famhomebase-kiosk"
      if [ "$was_active" -eq 1 ] && [ "$scripts_now" != "$scripts_before" ]; then systemctl --user restart famhomebase-kiosk.service >/dev/null 2>&1; fi
    fi
  else
    systemctl --user enable famhomebase-kiosk.service >/dev/null 2>&1
  fi
else
  say "  Could not reach your user's systemd (normal when run from a session with no desktop login yet). It starts at the next login; or run: systemctl --user enable --now famhomebase-kiosk.service famhomebase-host.path"
fi
printf '%s\n' "$scripts_now" > "$state" 2>/dev/null || true
