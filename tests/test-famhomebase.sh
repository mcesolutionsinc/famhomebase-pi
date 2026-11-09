#!/bin/sh
# Tests for scripts/famhomebase (the `famhomebase` command) with stubbed systemctl, docker, journalctl and sudo. Run: sh tests/test-famhomebase.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/lib" "$WORK/bin" "$WORK/usrbin"
cp "$HERE/../scripts/famhomebase" "$WORK/lib/famhomebase"
echo 0.3.0 > "$WORK/lib/VERSION"
printf '#!/bin/sh\necho "update.sh ran"\n' > "$WORK/lib/update.sh"
ln -s "$WORK/lib/famhomebase" "$WORK/usrbin/famhomebase" # as host-setup installs it: a link
printf '#!/bin/sh\n[ "$1" = is-active ] && { echo "${UNIT_STATE:-active}"; exit 0; }\n' > "$WORK/bin/systemctl"
printf '#!/bin/sh\ncase "$*" in *State.Health*) echo "${HEALTH:-healthy}" ;; esac\n[ -n "${NO_CONTAINER:-}" ] && exit 1; exit 0\n' > "$WORK/bin/docker"
printf '#!/bin/sh\necho "journalctl $*"\n' > "$WORK/bin/journalctl"
printf '#!/bin/sh\necho "sudo $*"\nexec "$@"\n' > "$WORK/bin/sudo"
chmod +x "$WORK/bin/"*
export SYSTEMCTL="$WORK/bin/systemctl" DOCKER="$WORK/bin/docker" JOURNALCTL="$WORK/bin/journalctl" PATH="$WORK/bin:$PATH" FAMHOMEBASE_ETC_DIR="$WORK/etc"
F="$WORK/usrbin/famhomebase"

out=$(sh "$F" version)
check "version: prints the installed version, found through the link in /usr/local/bin" "[ \"$out\" = 0.3.0 ]"
out=$(sh "$F" status)
check "status: the version, both units, and the container's health" "echo \"$out\" | grep -q 'display 0.3.0' && echo \"$out\" | grep -q 'famhomebase.service *active' && echo \"$out\" | grep -q 'famhomebase-update.timer *active' && echo \"$out\" | grep -q 'display container *healthy'"
check "no command means status" "sh $F | grep -q 'display 0.3.0'"
out=$(NO_CONTAINER=1 sh "$F" status)
check "status: a display that is not running says so" "echo \"$out\" | grep -q 'not running'"
out=$(sh "$F" logs)
check "logs: the display's and the updater's, last 100 lines by default" "echo \"$out\" | grep -q 'journalctl -u famhomebase -u famhomebase-update -n 100'"
out=$(sh "$F" logs 20)
check "logs: a number picks how many" "echo \"$out\" | grep -q -- '-n 20 '"
out=$(sh "$F" update)
check "update: runs the update script (through sudo when not root)" "echo \"$out\" | grep -q 'update.sh ran' && { [ \$(id -u) = 0 ] || echo \"$out\" | grep -q '^sudo sh '; }"
check "settings: where the settings file is" "[ \"\$(sh $F settings)\" = $WORK/etc/famhomebase.env ]"
sh "$F" bogus > "$WORK/out" 2>&1; st=$?
check "an unknown command is refused with the list" "[ $st = 2 ] && grep -q 'unknown command' $WORK/out"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
