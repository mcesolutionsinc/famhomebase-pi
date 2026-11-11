#!/bin/sh
# The boot splash: the FamHomeBase logo and three moving dots, shown by Plymouth from the first moment the kernel runs until the kiosk's
# first picture, turned the right way for how the screen is mounted. Run as root by host-setup.sh and by the famhomebase-splash service.
#
#   splash.sh install   everything the splash needs on this machine: the plymouth package, quiet boot settings, the state folder the
#                       page tells its rotation in, and the theme (made for the rotation known now)
#   splash.sh apply     make the theme again for the rotation in /var/lib/famhomebase/state/rotation, and rebuild the boot image if
#                       (and only if) it changed. The famhomebase-splash.path unit runs this when the page writes a new rotation.
#
# The rotation is how the screen is mounted (0, 90, 180 or 270, a setting of the device on the website). The display's page writes it to
# the file (its web server takes a PUT); a value that is not one of the four is taken as 0.
#
# Plymouth runs before anything else, so it cannot ask the cloud: the theme is made for one rotation, ahead of time. The logo's pictures
# and sizes are the same as the app's start screen (mobile/src/display/bootGeometry.ts in the app repo), so the handover looks like
# nothing changed.
set -u

LIB=$(cd "$(dirname "$0")" && pwd)
STATE_DIR=${FAMHOMEBASE_STATE_DIR:-/var/lib/famhomebase}
THEMES_DIR=${FAMHOMEBASE_PLYMOUTH_DIR:-/usr/share/plymouth/themes}
BOOT_DIR=${FAMHOMEBASE_BOOT_DIR:-$([ -d /boot/firmware ] && echo /boot/firmware || echo /boot)}
APT_GET=${APT_GET:-apt-get}
SET_THEME=${PLYMOUTH_SET_DEFAULT_THEME:-plymouth-set-default-theme}
GET_THEME=${PLYMOUTH_GET_DEFAULT_THEME:-plymouth-set-default-theme}
THEME=famhomebase
THEME_DIR="$THEMES_DIR/$THEME"
ROTATION_FILE="$STATE_DIR/state/rotation"

jlog() { printf '{"ts":"%s","level":"%s","component":"splash","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$2" | tr '"\\' "'/")"; }

rotation() {
  r=$(head -c 16 "$ROTATION_FILE" 2>/dev/null | tr -d ' \r\n')
  case "$r" in
    0|90|180|270) echo "$r" ;;
    '') echo 0 ;;
    *) jlog warn "the rotation file says '$r', which is not 0, 90, 180 or 270: using 0" >&2; echo 0 ;;
  esac
}

# The Plymouth script for one rotation. All sizes are fractions of the screen as the people in the room see it (turned the right way up);
# every part is then turned and placed for the panel's real shape. Keep these numbers equal to bootGeometry.ts in the app.
write_script() { # $1 = rotation, output on stdout
  cat <<SCRIPT_EOF
# FamHomeBase boot splash (made by splash.sh for a screen mounted turned $1 degrees). Do not edit: it is rewritten.
rotation = $1;
SCRIPT_EOF
  cat <<'SCRIPT_EOF'

Window.SetBackgroundTopColor(0.039, 0.075, 0.153);
Window.SetBackgroundBottomColor(0.039, 0.075, 0.153);

pw = Window.GetWidth();
ph = Window.GetHeight();
quarter = (rotation == 90 || rotation == 270);
if (quarter) { lw = ph; lh = pw; } else { lw = pw; lh = ph; }

# the pictures are already turned for this rotation (splash.sh copies the right ones in), so a quarter turn has them lying on their side:
# the upright shape is the other way round
if (lw >= lh) { logo = Image("wide.png"); fraction = 0.55; }
else { logo = Image("tall.png"); fraction = 0.7; }
if (quarter) { upright_w = logo.GetHeight(); upright_h = logo.GetWidth(); }
else { upright_w = logo.GetWidth(); upright_h = logo.GetHeight(); }

logo_w = lw * fraction;
logo_h = upright_h * logo_w / upright_w;
dot_d = logo_w * 0.03;
dots_offset = logo_h + logo_w * 0.1;
group_h = dots_offset + dot_d;
group_top = (lh - group_h) / 2;

# turning the positions the same way the pictures were turned: opposite to how the screen is mounted, so it reads upright on the wall
angle = (360 - rotation) * 3.14159265 / 180;
cs = Math.Cos(angle);
sn = Math.Sin(angle);

fun place(sprite, image, ox, oy) {
  # (ox, oy): the centre of the part, from the centre of the upright screen. Turn it, then put it there on the panel.
  px = ox * cs - oy * sn;
  py = ox * sn + oy * cs;
  sprite.SetPosition(pw / 2 + px - image.GetWidth() / 2, ph / 2 + py - image.GetHeight() / 2, 10);
}

if (quarter) { logo_img = logo.Scale(logo_h, logo_w); }
else { logo_img = logo.Scale(logo_w, logo_h); }
logo_sprite = Sprite(logo_img);
place(logo_sprite, logo_img, 0, group_top + logo_h / 2 - lh / 2);

dot_turned = Image("dot.png").Scale(dot_d, dot_d);
for (i = 0; i < 3; i++) {
  dots[i] = Sprite(dot_turned);
  place(dots[i], dot_turned, (i - 1) * 2 * dot_d, group_top + dots_offset + dot_d / 2 - lh / 2);
  dots[i].SetOpacity(0.3);
}

# The word "Updating" under the dots, there only while the display asks for it: `plymouth display-message --text=updating` shows it and
# `plymouth hide-message --text=updating` takes it away (scripts/first-update.sh, on the first boot only). It sits below the group, so the logo
# and the dots do not move when it appears. Its picture is turned for the rotation like the logo's.
label = Image("updating.png");
if (quarter) { label_up_w = label.GetHeight(); label_up_h = label.GetWidth(); }
else { label_up_w = label.GetWidth(); label_up_h = label.GetHeight(); }
label_w = logo_w * 0.3;
label_h = label_up_h * label_w / label_up_w;
if (quarter) { label_img = label.Scale(label_h, label_w); }
else { label_img = label.Scale(label_w, label_h); }
label_sprite = Sprite(label_img);
place(label_sprite, label_img, 0, group_top + group_h + logo_w * 0.05 + label_h / 2 - lh / 2);
label_sprite.SetOpacity(0);
fun show_label(text) { if (text == "updating") label_sprite.SetOpacity(1); }
fun hide_label(text) { label_sprite.SetOpacity(0); }
Plymouth.SetDisplayMessageFunction(show_label);
Plymouth.SetHideMessageFunction(hide_label);

# the dots light up in turn: a hump for half a wave, dark for the other half, each dot a fifth of a wave behind the one before.
# One wave is 60 refreshes (a little over a second).
frame = 0;
fun refresh() {
  frame++;
  if (frame >= 60) frame = 0;
  phase = frame / 60;
  for (i = 0; i < 3; i++) {
    own = phase - i * 0.2;
    if (own < 0) own = own + 1;
    lit = 0;
    if (own < 0.5) lit = Math.Sin(own * 2 * 3.14159265);
    dots[i].SetOpacity(0.3 + 0.7 * lit);
  }
}
Plymouth.SetRefreshFunction(refresh);
SCRIPT_EOF
}

write_theme_file() { # $1 = rotation: the theme's files into $2
  cat > "$2/$THEME.plymouth" <<PLY_EOF
[Plymouth Theme]
Name=FamHomeBase
Description=The FamHomeBase logo and three moving dots (and the word Updating when asked), turned for how the screen is mounted
ModuleName=script

[script]
ImageDir=$THEME_DIR
ScriptFile=$THEME_DIR/$THEME.script
PLY_EOF
  write_script "$1" > "$2/$THEME.script"
  # the pictures turned for this rotation (see tools/make-splash-assets.cjs), under the names the script uses
  cp "$LIB/splash/wide-$1.png" "$2/wide.png" && cp "$LIB/splash/tall-$1.png" "$2/tall.png" && cp "$LIB/splash/dot.png" "$2/dot.png" \
    && cp "$LIB/splash/updating-$1.png" "$2/updating.png"
}

apply() {
  rot=$(rotation)
  new=$(mktemp -d) || { jlog error "could not make a scratch folder"; return 1; }
  write_theme_file "$rot" "$new" || { rm -rf "$new"; jlog error "could not make the splash theme (are the splash pictures in $LIB/splash?)"; return 1; }
  changed=0
  if [ ! -d "$THEME_DIR" ] || ! diff -r "$new" "$THEME_DIR" >/dev/null 2>&1; then
    mkdir -p "$THEMES_DIR" && rm -rf "${THEME_DIR:?}" && mkdir "$THEME_DIR" && cp -R "$new/." "$THEME_DIR/" || { rm -rf "$new"; jlog error "could not install the splash theme"; return 1; }
    changed=1
  fi
  rm -rf "$new"
  current=$("$GET_THEME" 2>/dev/null | head -n 1)
  if [ "$changed" -eq 1 ] || [ "$current" != "$THEME" ]; then
    if "$SET_THEME" -R "$THEME" >/dev/null 2>&1; then
      jlog info "splash theme ready for rotation $rot and the boot image rebuilt (it shows from the next boot)"
    else
      jlog warn "the splash theme is written but the boot image could not be rebuilt: run: sudo plymouth-set-default-theme -R $THEME"
    fi
  else
    jlog info "splash theme already right for rotation $rot"
  fi
}

# Words on the kernel's command line (one line) that hide the boot log and the cursor: added when missing, anything else kept as it is.
boot_params() {
  cmdline="$BOOT_DIR/cmdline.txt"
  if [ -f "$cmdline" ]; then
    line=$(tr -d '\n' < "$cmdline")
    new=$line
    for p in quiet splash loglevel=3 logo.nologo vt.global_cursor_default=0 plymouth.ignore-serial-consoles; do
      key=${p%%=*}
      case " $new " in *" $key "*|*" $key="*) ;; *) new="$new $p" ;; esac
    done
    if [ "$new" != "$line" ]; then printf '%s\n' "$new" > "$cmdline.new" && mv "$cmdline.new" "$cmdline" && jlog info "added quiet-boot settings to $cmdline"; fi
  else
    jlog warn "no $cmdline: add 'quiet splash loglevel=3 logo.nologo vt.global_cursor_default=0' to the kernel command line by hand"
  fi
  config="$BOOT_DIR/config.txt"
  if [ -f "$config" ] && ! grep -q '^disable_splash=1' "$config"; then
    # under [all], so it applies to every model whatever section the file happened to end in
    printf '\n# FamHomeBase: no rainbow screen at power-up\n[all]\ndisable_splash=1\n' >> "$config" && jlog info "turned off the firmware's rainbow screen in $config"
  fi
}

install() {
  command -v plymouth >/dev/null 2>&1 || {
    jlog info "installing plymouth (the boot splash needs it)"
    DEBIAN_FRONTEND=noninteractive "$APT_GET" update -q >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive "$APT_GET" install -y -q plymouth >/dev/null 2>&1 || { jlog warn "could not install plymouth: the boot splash is skipped (sudo apt install plymouth, then run: sudo $LIB/splash.sh install)"; return 0; }
  }
  # the folder the page's web server writes the rotation into: the container's user must be able to write it
  mkdir -p "$STATE_DIR/state" && chmod 0777 "$STATE_DIR/state" 2>/dev/null
  boot_params
  apply
}

case "${1:-}" in
  install) install ;;
  apply) apply ;;
  *) echo "usage: splash.sh install | apply" >&2; exit 2 ;;
esac
