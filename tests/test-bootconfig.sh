#!/bin/sh
# Tests for scripts/bootconfig.sh. Run: sh tests/test-bootconfig.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/bootconfig.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/boot" "$WORK/etc"
export FAMHOMEBASE_BOOT_DIR="$WORK/boot" FAMHOMEBASE_ETC_DIR="$WORK/etc"
SRC="$WORK/boot/famhomebase.env"; DST="$WORK/etc/famhomebase.env"
reset() { rm -f "$SRC"; printf '# settings\nFAMHOMEBASE_ENV=prod\nFAMHOMEBASE_API_URL=https://famhomebase.mc-esolutions.ca\nAUTO_UPDATE=1\n' > "$DST"; }
run() { sh "$SCRIPT" > "$WORK/out" 2>&1; }

reset; run; st=$?
check "no file on the boot drive: does nothing, silent, exit 0" "[ $st = 0 ] && [ ! -s $WORK/out ] && grep -q '^FAMHOMEBASE_ENV=prod' $DST"
reset; printf 'FAMHOMEBASE_ENV=staging\n' > "$SRC"; run; st=$?
check "staging alone: sets the environment and fills in the staging address, deletes the file" "[ $st = 0 ] && grep -qx 'FAMHOMEBASE_ENV=staging' $DST && grep -qx 'FAMHOMEBASE_API_URL=https://staging.famhomebase.mc-esolutions.ca' $DST && [ ! -e $SRC ]"
check "the other settings in the real file are left alone" "grep -qx 'AUTO_UPDATE=1' $DST && grep -qx '# settings' $DST"
reset; printf 'FAMHOMEBASE_ENV=staging\nFAMHOMEBASE_API_URL=https://test.example.org:8443\n' > "$SRC"; run
check "an address given with it is used, not the default" "grep -qx 'FAMHOMEBASE_API_URL=https://test.example.org:8443' $DST"
reset; printf 'FAMHOMEBASE_API_URL=https://other.example.org\n' > "$SRC"; run
check "an address alone changes only the address" "grep -qx 'FAMHOMEBASE_API_URL=https://other.example.org' $DST && grep -qx 'FAMHOMEBASE_ENV=prod' $DST"
reset; printf 'FAMHOMEBASE_ENV=staging\r\nFAMHOMEBASE_API_URL="https://q.example.org"\r\n' > "$SRC"; run
check "Windows line endings and quotes are not part of the values" "grep -qx 'FAMHOMEBASE_ENV=staging' $DST && grep -qx 'FAMHOMEBASE_API_URL=https://q.example.org' $DST"
reset; printf 'FAMHOMEBASE_ENV=dev\n' > "$SRC"; run; st=$?
check "a bad environment: nothing changes, the file stays, an error in the log, exit 0" "[ $st = 0 ] && grep -qx 'FAMHOMEBASE_ENV=prod' $DST && [ -f $SRC ] && grep -q '\"level\":\"error\"' $WORK/out"
reset; printf 'FAMHOMEBASE_ENV=staging\nFAMHOMEBASE_API_URL=http://insecure.example.org\n' > "$SRC"; run; st=$?
check "an address that is not https is refused (nothing is applied, not even the environment)" "[ $st = 0 ] && grep -qx 'FAMHOMEBASE_ENV=prod' $DST && [ -f $SRC ] && grep -q 'https://host' $WORK/out"
reset; printf 'FAMHOMEBASE_API_URL=https://x.example.org/path\n' > "$SRC"; run
check "an address with a path is refused" "[ -f $SRC ] && grep -q 'with no path' $WORK/out"
reset; printf 'FAMHOMEBASE_ENV=staging\nAUTO_UPDATE=0\nSECRET_THING=abc\n' > "$SRC"; run
check "other settings are ignored, named in a warning without their values, and not applied" "grep -qx 'AUTO_UPDATE=1' $DST && ! grep -q SECRET_THING $DST && grep -q 'ignored settings.*AUTO_UPDATE,SECRET_THING' $WORK/out && ! grep -q abc $WORK/out"
reset; printf '# nothing useful\n' > "$SRC"; run
check "a file with neither setting changes nothing and stays" "[ -f $SRC ] && grep -q 'nothing to apply' $WORK/out"
reset; rm "$DST"; printf 'FAMHOMEBASE_ENV=staging\n' > "$SRC"; run; st=$?
check "no real settings file yet: nothing is written, the file stays, exit 0" "[ $st = 0 ] && [ ! -e $DST ] && [ -f $SRC ] && grep -q 'no settings file' $WORK/out"
reset; printf 'FAMHOMEBASE_ENV=staging\n' > "$SRC"; run
check "its log lines are JSON" "grep -q '^{\"ts\":\".*\"level\":\"info\",\"component\":\"bootconfig\"' $WORK/out"
reset; printf 'FAMHOMEBASE_ENV=staging\n' > "$SRC"; printf 'FAMHOMEBASE_ENV=prod\n' > "$DST"; run
check "a settings file that lacks the address line gets it added" "grep -qx 'FAMHOMEBASE_API_URL=https://staging.famhomebase.mc-esolutions.ca' $DST"

reset; printf 'FAMHOMEBASE_ENV=Staging  \nFAMHOMEBASE_API_URL=  https://sp.example.org \n' > "$SRC"; run
check "trailing spaces and a capital letter (an editor's habits) do not stop it working" "grep -qx 'FAMHOMEBASE_ENV=staging' $DST && grep -qx 'FAMHOMEBASE_API_URL=https://sp.example.org' $DST && [ ! -e $SRC ]"
reset; printf 'FAMHOMEBASE_API_URL=https://good.example.org\\nAUTO_UPDATE=0\n' > "$SRC"; run
check "a backslash in a value cannot add lines to the real file (dash echo would have turned it into a newline)" "[ \"\$(grep -c AUTO_UPDATE $DST)\" = 1 ] && grep -qx 'AUTO_UPDATE=1' $DST && [ -f $SRC ] && grep -q 'https://host' $WORK/out"
reset; printf 'FAMHOMEBASE_ENV=prod\nFAMHOMEBASE_ENV=staging\n' > "$SRC"; run
check "a key given twice: the last line wins" "grep -qx 'FAMHOMEBASE_ENV=staging' $DST"
reset; chmod 640 "$DST"; printf 'FAMHOMEBASE_ENV=staging\n' > "$SRC"; run
check "the real settings file keeps its permissions" "[ \"\$(stat -c %a $DST)\" = 640 ]"
if [ "$(id -u)" -ne 0 ]; then
  reset; chmod 444 "$DST"; printf 'FAMHOMEBASE_ENV=staging\n' > "$SRC"; run; st=$?
  check "a settings file that cannot be written: an error, no false 'applied', the boot-drive file stays, exit 0" "[ $st = 0 ] && [ -f $SRC ] && grep -q 'could not write' $WORK/out && ! grep -q '\"level\":\"info\"' $WORK/out && grep -qx 'FAMHOMEBASE_ENV=prod' $DST && [ ! -e $DST.work ]"
  chmod 644 "$DST"
else ok "(running as root: the unwritable-file test is skipped)"; fi
echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
