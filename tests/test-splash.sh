#!/bin/sh
# Tests for scripts/splash.sh with stubbed plymouth-set-default-theme and apt-get, writing into scratch folders. Run: sh tests/test-splash.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/splash.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/set-theme" <<'STUB'
#!/bin/sh
# plymouth-set-default-theme: with -R NAME sets (and records a rebuild); with nothing prints the current theme
if [ "${1:-}" = -R ]; then echo "rebuild $2" >> "$LOG"; [ -n "${FAIL_REBUILD:-}" ] && exit 1; echo "$2" > "$WORK/current-theme"; exit 0; fi
cat "$WORK/current-theme" 2>/dev/null || echo text
STUB
printf '#!/bin/sh\necho "apt-get $*" >> "$LOG"\n[ -z "${FAIL_APT:-}" ]\n' > "$WORK/bin/apt-get"
mkdir -p "$WORK/tools"; printf '#!/bin/sh\n' > "$WORK/tools/plymouth"; chmod +x "$WORK/tools/plymouth"
chmod +x "$WORK/bin/"*
# a PATH with only the system tools the script uses (and the stubs), where plymouth must be missing: a machine that has it must not leak in
mkdir -p "$WORK/min"
for t in sh head tr cat date mktemp diff cp mkdir rm chmod mv dirname grep wc cut stat env printf; do ln -sf "$(command -v $t)" "$WORK/min/$t" 2>/dev/null; done
MINPATH="$WORK/bin:$WORK/min"
export PATH="$WORK/tools:$PATH" LOG="$WORK/log" WORK
export FAMHOMEBASE_STATE_DIR="$WORK/state" FAMHOMEBASE_PLYMOUTH_DIR="$WORK/themes" FAMHOMEBASE_BOOT_DIR="$WORK/boot"
export PLYMOUTH_SET_DEFAULT_THEME="$WORK/bin/set-theme" PLYMOUTH_GET_DEFAULT_THEME="$WORK/bin/set-theme" APT_GET="$WORK/bin/apt-get"
T="$WORK/themes/famhomebase"

fresh() {
  rm -rf "${WORK:?}/inst" "${WORK:?}/state" "${WORK:?}/themes" "${WORK:?}/boot" "$WORK/current-theme"; : > "$LOG"
  mkdir -p "$WORK/inst/splash" "$WORK/boot"
  cp "$SCRIPT" "$WORK/inst/"
  cp "$HERE"/../assets/splash/*.png "$WORK/inst/splash/"
  printf 'console=serial0,115200 console=tty1 root=PARTUUID=x rootwait quiet splash plymouth.ignore-serial-consoles ds=nocloud;i=rpi-imager-1 cfg80211.ieee80211_regdom=CA\n' > "$WORK/boot/cmdline.txt"
  printf 'dtparam=audio=on\n[all]\n' > "$WORK/boot/config.txt"
  mkdir -p "$WORK/state/state"
  unset FAIL_REBUILD FAIL_APT
}
splash() { sh "$WORK/inst/splash.sh" "$@" > "$WORK/out" 2> "$WORK/err"; }
setrot() { printf '%s' "$1" > "$WORK/state/state/rotation"; }

fresh; splash apply; st=$?
check "apply with no rotation file: the theme for 0 degrees, its pictures, and a rebuild of the boot image" "[ $st = 0 ] && grep -q '^rotation = 0;' $T/famhomebase.script && [ -f $T/wide.png ] && [ -f $T/tall.png ] && [ -f $T/dot.png ] && grep -q '^rebuild famhomebase' \$LOG"
check "the theme's pictures are the ones turned for this rotation, under the names the script uses" "cmp -s $T/wide.png $WORK/inst/splash/wide-0.png && cmp -s $T/tall.png $WORK/inst/splash/tall-0.png"
fresh; setrot 270; splash apply
check "for 270 degrees: the pictures turned for 270" "cmp -s $T/wide.png $WORK/inst/splash/wide-270.png && cmp -s $T/tall.png $WORK/inst/splash/tall-270.png && ! cmp -s $T/tall.png $WORK/inst/splash/tall-0.png"
check "the word Updating: its picture is the one turned for the rotation, under the name the script uses (updating.png)" "cmp -s $T/updating.png $WORK/inst/splash/updating-270.png && ! cmp -s $T/updating.png $WORK/inst/splash/updating-0.png"
check "the word is hidden to begin with, shown by display-message updating and taken away by hide-message, and sits below the dots so the logo does not move" "grep -q 'label_sprite.SetOpacity(0);' $T/famhomebase.script && grep -q 'SetDisplayMessageFunction(show_label)' $T/famhomebase.script && grep -q 'SetHideMessageFunction(hide_label)' $T/famhomebase.script && grep -q 'text == \"updating\"' $T/famhomebase.script && grep -q 'group_top + group_h' $T/famhomebase.script"
check "the script does not use Plymouth's own image rotation (it crops the picture to its old shape)" "! grep -q 'Rotate' $T/famhomebase.script"
fresh; splash apply
check "the theme file names the script module and its folder" "grep -q '^ModuleName=script' $T/famhomebase.plymouth && grep -q '^ImageDir=$T\$' $T/famhomebase.plymouth && grep -q '^ScriptFile=$T/famhomebase.script\$' $T/famhomebase.plymouth"
check "the script has the logo shapes, the dots and the wave of the app's start screen (the same numbers as bootGeometry.ts)" "grep -q 'fraction = 0.55' $T/famhomebase.script && grep -q 'fraction = 0.7' $T/famhomebase.script && grep -q 'dot_d = logo_w \\* 0.03' $T/famhomebase.script && grep -q 'logo_w \\* 0.1' $T/famhomebase.script && grep -q 'i \\* 0.2' $T/famhomebase.script && grep -q 'frame >= 60' $T/famhomebase.script && grep -q 'SetBackgroundTopColor(0.039, 0.075, 0.153)' $T/famhomebase.script"
check "its log line is JSON" "grep -q '^{\"ts\":\".*\"component\":\"splash\"' \$WORK/out"

fresh; setrot 90; splash apply
check "a rotation file of 90: the theme is made for 90 degrees" "grep -q '^rotation = 90;' $T/famhomebase.script"
for r in 180 270; do fresh; setrot $r; splash apply; check "rotation $r" "grep -q '^rotation = $r;' $T/famhomebase.script"; done
fresh; setrot "90
"; splash apply
check "a newline after the value is fine" "grep -q '^rotation = 90;' $T/famhomebase.script"
fresh; setrot sideways; splash apply
check "a value that is not a rotation is taken as 0, with a warning that says so" "grep -q '^rotation = 0;' $T/famhomebase.script && grep -q 'not 0, 90, 180 or 270' \$WORK/err"
fresh; setrot '90; evil'; splash apply
check "and cannot put code into the script" "grep -q '^rotation = 0;' $T/famhomebase.script && ! grep -q evil $T/famhomebase.script"

fresh; splash apply; : > "$LOG"; splash apply
check "applying again with nothing changed does not rebuild the boot image" "! grep -q rebuild \$LOG && grep -q 'already right' \$WORK/out"
setrot 90; splash apply
check "a new rotation makes the theme again and rebuilds once" "grep -q '^rotation = 90;' $T/famhomebase.script && [ \$(grep -c '^rebuild' \$LOG) = 1 ]"
: > "$LOG"; splash apply
check "and not again" "! grep -q rebuild \$LOG"
fresh; splash apply; echo text > "$WORK/current-theme"; : > "$LOG"; splash apply
check "if the default theme was changed to another, it is put back (even though the files are unchanged)" "grep -q '^rebuild famhomebase' \$LOG"
fresh; FAIL_REBUILD=1 splash apply; st=$?
check "a rebuild that fails is a warning that says what to run, not a failure" "[ $st = 0 ] && grep -q 'plymouth-set-default-theme -R famhomebase' \$WORK/out"
fresh; rm -f "$WORK/inst/splash/updating-0.png"; splash apply; st=$?
check "a missing Updating picture is a missing picture too: an error, and nothing is installed" "[ $st != 0 ] && [ ! -d $T ] && ! grep -q rebuild \$LOG"
fresh; rm -f "$WORK/inst/splash/tall-0.png"; splash apply; st=$?
check "missing pictures: an error, and nothing is installed or rebuilt" "[ $st != 0 ] && [ ! -d $T ] && ! grep -q rebuild \$LOG && grep -q '\"level\":\"error\"' \$WORK/out"

# install
fresh; splash install; st=$?
check "install with plymouth there: no apt, the theme is made" "[ $st = 0 ] && ! grep -q '^apt-get' \$LOG && [ -f $T/famhomebase.script ]"
check "the state folder is made and the web server's user can write in it" "[ -d $WORK/state/state ] && [ \"\$(stat -c %a $WORK/state/state)\" = 777 ]"
check "quiet-boot words are added to the kernel command line, and the rest of it (the Imager's cloud-init words too) is kept as it was" "grep -q 'ds=nocloud;i=rpi-imager-1' $WORK/boot/cmdline.txt && grep -q 'console=tty1' $WORK/boot/cmdline.txt && grep -q ' loglevel=3' $WORK/boot/cmdline.txt && grep -q ' logo.nologo' $WORK/boot/cmdline.txt && grep -q ' vt.global_cursor_default=0' $WORK/boot/cmdline.txt && [ \$(wc -l < $WORK/boot/cmdline.txt) = 1 ]"
check "words already there (quiet, splash) are not doubled" "[ \$(grep -o ' quiet' $WORK/boot/cmdline.txt | wc -l) = 1 ] && [ \$(grep -o ' splash' $WORK/boot/cmdline.txt | wc -l) = 1 ]"
check "the firmware's rainbow screen is turned off, under [all] so it applies to every model" "grep -q '^disable_splash=1' $WORK/boot/config.txt && [ \"\$(tail -n 2 $WORK/boot/config.txt | head -n 1)\" = '[all]' ]"
cp "$WORK/boot/cmdline.txt" "$WORK/cmd.1"; cp "$WORK/boot/config.txt" "$WORK/cfg.1"; splash install
check "running install again changes nothing" "cmp -s $WORK/boot/cmdline.txt $WORK/cmd.1 && cmp -s $WORK/boot/config.txt $WORK/cfg.1"
fresh; printf 'quiet splash=0 console=tty1\n' > "$WORK/boot/cmdline.txt"; splash install
check "a word the owner set in their own way (splash=0) is respected, not added again" "grep -q 'splash=0' $WORK/boot/cmdline.txt && [ \$(grep -o 'splash' $WORK/boot/cmdline.txt | wc -l) = 1 ]"
fresh; rm -f "$WORK/boot/cmdline.txt"; splash install; st=$?
check "no cmdline file is a warning, and the rest still happens" "[ $st = 0 ] && grep -q 'no .*cmdline.txt' \$WORK/out && [ -f $T/famhomebase.script ]"
fresh; PATH="$MINPATH" splash install
check "plymouth missing: the package lists are refreshed, then it is installed with apt" "[ \"\$(grep -n '^apt-get update' \$LOG | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '^apt-get install' \$LOG | head -1 | cut -d: -f1)\" ] && grep -q 'apt-get install -y -q plymouth' \$LOG"
fresh; FAIL_APT=1 PATH="$MINPATH" splash install; st=$?
check "plymouth that cannot be installed: a warning, no failure, no half-made theme" "[ $st = 0 ] && grep -q 'could not install plymouth' \$WORK/out && [ ! -d $T ]"
fresh; PATH="$MINPATH" FAIL_APT=1 splash install; : > "$LOG"; PATH="$MINPATH" splash install
check "and the next install tries to install it again (a folder made by the failed run does not count as plymouth being there)" "grep -q '^apt-get install' \$LOG"

fresh; splash bogus; st=$?
check "an unknown command is refused" "[ $st = 2 ]"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
