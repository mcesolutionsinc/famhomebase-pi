#!/bin/sh
# Tests for scripts/first-update.sh (the first-boot update, ticket 58) with a stubbed updater, network check and splash command. No root, no
# systemd, no network. Run: sh tests/test-first-update.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/first-update.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
LIB="$WORK/lib"; STATE="$WORK/state"; RUN="$WORK/run"; M="$STATE/first-boot-update-done"; LOG="$WORK/calls.log"
mkdir -p "$WORK/bin"
# the network check: succeeds unless a test says there is none
cat > "$WORK/bin/curl" <<STUB
#!/bin/sh
echo "curl \$*" >> "$LOG"
if [ -n "\${CURL_FAIL_FIRST:-}" ]; then c=\$(cat "$WORK/curlcount" 2>/dev/null || echo 0); c=\$((c + 1)); echo \$c > "$WORK/curlcount"; [ "\$c" -gt "\$CURL_FAIL_FIRST" ]; exit \$?; fi
[ -z "\${CURL_FAIL:-}" ]
STUB
# a clock that jumps by days at every look (what the network does to a Pi's clock when it first sets it): only +%s, everything else is the real date
mkdir -p "$WORK/clock"
cat > "$WORK/clock/date" <<STUB
#!/bin/sh
if [ "\$1" = "+%s" ]; then c=\$(cat "$WORK/clockcount" 2>/dev/null || echo 0); c=\$((c + 1)); echo \$c > "$WORK/clockcount"; echo \$((c * 500000)); exit 0; fi
exec /bin/date "\$@"
STUB
chmod +x "$WORK/clock/date"
# the splash command: --ping says whether it is running; every other call is noted
cat > "$WORK/bin/plymouth" <<'STUB'
#!/bin/sh
[ "$1" = --ping ] && { [ -z "${NO_SPLASH:-}" ]; exit $?; }
echo "plymouth $*" >> "$LOG"
STUB
# a short wait, so the tests are quick (the real one waits a second)
printf '#!/bin/sh\nexec sleep 0.2\n' > "$WORK/bin/nap"
# the updater, as the script finds it: what it says and does is chosen by UPDATE_MODE. It notes whether the flag was there while it ran, and
# whether the script that started it is running from a copy (the real updater replaces the folder the script lives in, and a shell reads its script
# as it runs, so the script must not be running from the file that is replaced).
cat > "$WORK/update.sh.stub" <<'STUB'
#!/bin/sh
LIB=$(cd "$(dirname "$0")" && pwd)
echo "updater ran; flag present: $([ -e "$FAMHOMEBASE_RUN_DIR/first-boot-update" ] && echo yes || echo no); copy: ${FAMHOMEBASE_FIRST_UPDATE_COPY:-no}; original: ${FAMHOMEBASE_FIRST_UPDATE_ORIG:-none}" >> "$LOG"
case "${UPDATE_MODE:-}" in
  newer)
    echo '{"level":"info","component":"update","msg":"updating 1.0.0 to 1.1.0"}'
    sleep 1
    echo 1.1.0 > "$LIB/VERSION"
    echo '{"level":"info","component":"update","msg":"updated 1.0.0 to 1.1.0"}' ;;
  fail)
    echo '{"level":"info","component":"update","msg":"updating 1.0.0 to 1.1.0"}'
    sleep 1
    echo '{"level":"error","component":"update","msg":"the display did not become healthy: putting the old version back"}'
    exit 1 ;;
  slow)
    echo '{"level":"info","component":"update","msg":"updating 1.0.0 to 1.1.0"}'
    sleep 30
    echo "updater finished" >> "$LOG"; echo 1.1.0 > "$LIB/VERSION" ;;
  swapping)
    echo '{"level":"info","component":"update","msg":"updating 1.0.0 to 1.1.0"}'
    sleep 1
    mkdir -p "$FAMHOMEBASE_STATE_DIR/rollback"
    sleep 3
    echo 1.1.0 > "$LIB/VERSION"; echo "updater finished" >> "$LOG" ;;
  uptodate) echo '{"level":"info","component":"update","msg":"up to date at 1.0.0"}' ;;
  lookup)   echo '{"level":"warn","component":"update","msg":"could not look up the latest release (offline?); will try again at the next check"}' ;;
  disabled) echo '{"level":"info","component":"update","msg":"release 1.1.0 is available (AUTO_UPDATE is off, so not installing)"}' ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/"*

fresh() {
  rm -rf "$LIB" "$STATE" "$RUN" "$WORK/tmp" "$WORK/curlcount" "$WORK/clockcount"; : > "$LOG"
  mkdir -p "$LIB" "$STATE" "$WORK/tmp"
  cp "$SCRIPT" "$LIB/first-update.sh"; cp "$WORK/update.sh.stub" "$LIB/update.sh"; echo 1.0.0 > "$LIB/VERSION"
  unset CURL_FAIL CURL_FAIL_FIRST NO_SPLASH UPDATE_MODE CLOCK_JUMPS LIMIT
}
run() { # extra arguments to the script
  env TMPDIR="$WORK/tmp" FAMHOMEBASE_LIB_DIR="$LIB" FAMHOMEBASE_STATE_DIR="$STATE" FAMHOMEBASE_RUN_DIR="$RUN" FAMHOMEBASE_FIRST_UPDATE_NET_SECONDS="${NET:-1}" \
    PATH="${CLOCK_JUMPS:+$WORK/clock:}$PATH" FAMHOMEBASE_FIRST_UPDATE_LIMIT_SECONDS="${LIMIT:-900}" \
    CURL="$WORK/bin/curl" PLYMOUTH="$WORK/bin/plymouth" SLEEP="$WORK/bin/nap" LOG="$LOG" UPDATE_MODE="${UPDATE_MODE:-}" CURL_FAIL="${CURL_FAIL:-}" CURL_FAIL_FIRST="${CURL_FAIL_FIRST:-}" NO_SPLASH="${NO_SPLASH:-}" \
    sh "$LIB/first-update.sh" "$@" > "$WORK/out" 2>&1
}

# a newer release: the word, the update, the marker
fresh; UPDATE_MODE=newer run; st=$?
check "a newer release is installed: exit 0, the marker says updated, and the version is the new one" "[ $st = 0 ] && grep -q '^updated [0-9]' $M && [ \"\$(cat $LIB/VERSION)\" = 1.1.0 ]"
check "the splash says Updating once the updater starts installing, and the word is taken away when it is done" "[ \"\$(grep -c 'plymouth display-message --text=updating' $LOG)\" = 1 ] && [ \"\$(grep -c 'plymouth hide-message --text=updating' $LOG)\" = 1 ] && [ \"\$(grep -n 'display-message' $LOG | cut -d: -f1)\" -lt \"\$(grep -n 'hide-message' $LOG | cut -d: -f1)\" ]"
check "the updater ran once, with the flag that keeps the kiosk from restarting, and the flag is gone afterwards" "[ \"\$(grep -c 'updater ran' $LOG)\" = 1 ] && grep -q 'flag present: yes' $LOG && [ ! -e $RUN/first-boot-update ]"
check "the script runs from a copy of itself while the updater replaces its folder, and the copy is gone afterwards" "grep -q 'copy: 1; original: $LIB/first-update.sh' $LOG && grep -q 'first-boot update: updated' $WORK/out && [ -z \"\$(ls -A $WORK/tmp)\" ]"
check "the updater's own lines are passed on, and its own are JSON" "grep -q '\"msg\":\"updated 1.0.0 to 1.1.0\"' $WORK/out && grep -q '^{\"ts\":\".*\"component\":\"first-update\"' $WORK/out"

# already the newest: nothing is shown
fresh; UPDATE_MODE=uptodate run; st=$?
check "already the newest: the marker says so, and the splash never says Updating" "[ $st = 0 ] && grep -q '^up-to-date [0-9]' $M && ! grep -q 'display-message' $LOG"

# no network
fresh; CURL_FAIL=1 run; st=$?
check "no network within the wait: the marker says offline, the updater is never run, and the screen goes on (exit 0)" "[ $st = 0 ] && grep -q '^offline [0-9]' $M && ! grep -q 'updater ran' $LOG && grep -q 'no network after 1s' $WORK/out && [ ! -e $RUN/first-boot-update ]"
fresh; UPDATE_MODE=lookup run; st=$?
check "a network that cannot reach the release list: offline too" "[ $st = 0 ] && grep -q '^offline [0-9]' $M && ! grep -q 'display-message' $LOG"

# settings say no
fresh; UPDATE_MODE=disabled run; st=$?
check "automatic updates turned off in the settings: the marker says disabled, nothing is installed" "[ $st = 0 ] && grep -q '^disabled [0-9]' $M && [ \"\$(cat $LIB/VERSION)\" = 1.0.0 ]"

# failure
fresh; UPDATE_MODE=fail run; st=$?
check "an update that fails and rolls back: exit 0 (never fails the boot), the marker says failed, the old version is kept, and the word is taken away (never stuck on Updating)" "[ $st = 0 ] && grep -q '^failed [0-9]' $M && [ \"\$(cat $LIB/VERSION)\" = 1.0.0 ] && grep -q 'hide-message' $LOG"

# no splash running (an install that is not a kiosk)
fresh; NO_SPLASH=1 UPDATE_MODE=newer run; st=$?
check "where no splash is running the update still happens, and no splash command is called" "[ $st = 0 ] && grep -q '^updated [0-9]' $M && ! grep -q 'plymouth' $LOG"

# never twice
fresh; echo 'up-to-date 1' > "$M"; UPDATE_MODE=newer run; st=$?
check "with the marker there, nothing happens: no network check, no updater" "[ $st = 0 ] && ! grep -q 'updater ran' $LOG && ! grep -q '^curl' $LOG && grep -q 'already done (up-to-date)' $WORK/out"

# the clock of a Pi with no battery steps when the network sets it: the wait for the network must not run out because of it
fresh; CLOCK_JUMPS=1 CURL_FAIL_FIRST=2 NET=3 UPDATE_MODE=uptodate run; st=$?
check "the wall clock jumping by days while it waits for the network does not make it give up: the network came up, so the update ran" "[ $st = 0 ] && grep -q '^up-to-date [0-9]' $M && grep -q 'updater ran' $LOG && [ \"\$(cat $WORK/clockcount)\" -ge 1 ]"

# the 15 minutes (here one second): stopped while only downloading, let finish once it is swapping
fresh; UPDATE_MODE=slow LIMIT=1 run; st=$?
check "still downloading when the time is up: the updater is stopped, the word is timeout, the old version is kept, and the Updating word is taken away" "[ $st = 0 ] && grep -q '^timeout [0-9]' $M && ! grep -q 'updater finished' $LOG && [ \"\$(cat $LIB/VERSION)\" = 1.0.0 ] && grep -q 'hide-message' $LOG && grep -q 'stopping it (nothing has been changed yet)' $WORK/out"
fresh; UPDATE_MODE=swapping LIMIT=2 run; st=$?
check "swapping when the time is up: it is let finish (never stopped half way), and the word is updated" "[ $st = 0 ] && grep -q '^updated [0-9]' $M && grep -q 'updater finished' $LOG && [ \"\$(cat $LIB/VERSION)\" = 1.1.0 ] && ! grep -q 'stopping it' $WORK/out"

# this script reads the updater's words: they must still be the ones it says
UPDATER="$HERE/../scripts/update.sh"
check "the words this script looks for are still the ones update.sh says (a rewording there must come here too)" "grep -q 'jlog info \"updating \$current to \$latest\"' $UPDATER && grep -q 'jlog info \"up to date at ' $UPDATER && grep -q 'could not look up the latest release' $UPDATER && grep -q 'could not read the latest release' $UPDATER && grep -q 'AUTO_UPDATE is off' $UPDATER && grep -q '\"msg\":\"%s\"' $UPDATER"

# stopped by systemd after the time limit
fresh; mkdir -p "$RUN"; : > "$RUN/first-boot-update"; run --after-stop; st=$?
check "after systemd had to stop it: --after-stop writes the word timeout and takes the flag away" "[ $st = 0 ] && grep -q '^timeout [0-9]' $M && [ ! -e $RUN/first-boot-update ]"
fresh; echo 'updated 5' > "$M"; run --after-stop; st=$?
check "after a normal finish --after-stop leaves the word that is there" "[ $st = 0 ] && grep -Fxq 'updated 5' $M"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
