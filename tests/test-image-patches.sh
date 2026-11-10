#!/bin/sh
# Tests for tools/image-patches.sh on a fake root folder. Run: sh tests/test-image-patches.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../tools/image-patches.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
R="$WORK/root"; U="$R/etc/systemd/system"
fresh() { # a fake system as the 0.5.8 installer leaves it
  rm -rf "$R"; mkdir -p "$U" "$R/usr/local/lib/famhomebase" "$R/etc/ssh"
  : > "$R/usr/local/lib/famhomebase/load-image.sh"; : > "$U/famhomebase-image-load.service"
  : > "$R/usr/local/lib/famhomebase/bootconfig.sh"; : > "$U/famhomebase-bootconfig.service"
  printf '[Unit]\nDescription=kiosk\nConflicts=getty@tty1.service\n\n[Service]\nExecStartPre=-+/usr/bin/chvt 1\nExecStart=/usr/bin/cage -- "/usr/local/lib/famhomebase/kiosk.sh"\nRestart=always\n' > "$U/famhomebase-kiosk.service"
  printf '127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n' > "$R/etc/hosts"; echo raspberrypi > "$R/etc/hostname"
  echo key > "$R/etc/ssh/ssh_host_ed25519_key"; echo pub > "$R/etc/ssh/ssh_host_ed25519_key.pub"
}
run() { sh "$SCRIPT" "$R" "$@" > "$WORK/out" 2>&1; }

fresh; run; st=$?
check "a normal run succeeds with JSON log lines" "[ $st = 0 ] && grep -q '^{\"ts\":\".*\"component\":\"image-patches\"' $WORK/out"
K="$U/famhomebase-kiosk.service"
check "the kiosk unit loses Conflicts=getty@tty1 and stops the prompt itself, before cage starts" "! grep -q '^Conflicts=getty' $K && [ \"\$(grep -n 'stop getty@tty1' $K | cut -d: -f1)\" -lt \"\$(grep -n '^ExecStart=/usr/bin/cage' $K | cut -d: -f1)\" ]"
check "getty@tty1 becomes a do-nothing service (not masked) that leaves the screen alone" "grep -q '^ExecStart=/bin/sleep infinity' $U/getty@tty1.service.d/10-noop.conf && grep -q '^TTYVHangup=no' $U/getty@tty1.service.d/10-noop.conf && [ ! -L $U/getty@tty1.service ]"
check "the rename-user question is switched off (userconfig.service -> /dev/null)" "[ \"\$(readlink $U/userconfig.service)\" = /dev/null ]"
check "SSH makes its host keys before the unit's own sshd -t check" "[ \"\$(grep -n 'ssh-keygen -A' $U/ssh.service.d/famhomebase-hostkeys.conf | cut -d: -f1)\" -lt \"\$(grep -n 'sshd -t' $U/ssh.service.d/famhomebase-hostkeys.conf | cut -d: -f1)\" ]"
check "no SSH host keys are left in the image" "[ -z \"\$(ls $R/etc/ssh/ssh_host_* 2>/dev/null)\" ]"
run; st=$?
check "running it twice leaves one stop line" "[ $st = 0 ] && [ \"\$(grep -c 'stop getty@tty1' $K)\" = 1 ]"

fresh; printf '[Unit]\nDescription=kiosk\n\n[Service]\nExecStartPre=-+/bin/systemctl stop getty@tty1.service\nExecStart=/usr/bin/cage -- "x"\n' > "$K"; run; st=$?
check "a kiosk unit that is already written the new way is accepted" "[ $st = 0 ] && [ \"\$(grep -c 'stop getty@tty1' $K)\" = 1 ]"
fresh; printf '[Service]\nExecStart=/usr/bin/something-else\nConflicts=getty@tty1.service\n' > "$K"; run; st=$?
check "a kiosk unit the script does not know is refused, with a reason (not silently left wrong)" "[ $st != 0 ] && grep -q 'could not change the kiosk unit' $WORK/out"
fresh; rm "$U/famhomebase-kiosk.service"; run; st=$?
check "a missing kiosk unit is refused" "[ $st != 0 ] && grep -q 'kiosk unit is not in the image' $WORK/out"
fresh; rm "$U/famhomebase-image-load.service"; run; st=$?
check "a release without the first-boot loader is refused, and says which release to use" "[ $st != 0 ] && grep -q 'needs a release 0.5.10 or later' $WORK/out"

fresh; rm "$U/famhomebase-bootconfig.service"; run; st=$?
check "a release without the boot-drive settings step is refused, and says which release to use" "[ $st != 0 ] && grep -q 'boot-drive settings step' $WORK/out && grep -q 'needs a release 0.5.10 or later' $WORK/out"
fresh; run --hostname kitchen; st=$?
check "a host name is written to /etc/hostname and replaces the 127.0.1.1 line" "[ $st = 0 ] && [ \"\$(cat $R/etc/hostname)\" = kitchen ] && grep -q '^127.0.1.1.kitchen\$' $R/etc/hosts && ! grep -q raspberrypi $R/etc/hosts"
fresh; printf '127.0.0.1\tlocalhost\n' > "$R/etc/hosts"; run --hostname kitchen; st=$?
check "a hosts file with no 127.0.1.1 line gets one (the name must resolve)" "[ $st = 0 ] && grep -q '^127.0.1.1.kitchen\$' $R/etc/hosts"
fresh; run --bogus; st=$?
check "an unknown option is refused" "[ $st != 0 ] && grep -q 'unknown option' $WORK/out"
sh "$SCRIPT" "$WORK/nothere" > "$WORK/out" 2>&1; st=$?
check "a root folder that does not exist is refused" "[ $st != 0 ] && grep -q usage $WORK/out"

echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
