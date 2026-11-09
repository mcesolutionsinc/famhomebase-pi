#!/bin/sh
# Tests for tools/build-image.sh: the argument and environment checks only (the build itself needs root, loop devices and a 64-bit ARM
# machine, so it is exercised by the image-spike workflow). Run: sh tests/test-build-image.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../tools/build-image.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# every tool the script checks for, as an empty stub, so only the checks under test can fail
for t in curl xz parted losetup mount umount chroot e2fsck resize2fs docker gzip; do printf '#!/bin/sh\n' > "$WORK/bin/$t"; chmod +x "$WORK/bin/$t"; done
printf '#!/bin/sh\necho aarch64\n' > "$WORK/uname-arm"; chmod +x "$WORK/uname-arm"
printf '#!/bin/sh\necho x86_64\n' > "$WORK/uname-x86"; chmod +x "$WORK/uname-x86"
run() { PATH="$WORK/bin:$PATH" FAMHOMEBASE_NO_ROOT=1 FAMHOMEBASE_UNAME="${UN:-$WORK/uname-arm}" "$@" sh "$SCRIPT" $ARGS > "$WORK/out" 2>&1; }
runner() { ARGS="$1" PATH="$WORK/bin:$PATH" FAMHOMEBASE_NO_ROOT=1 FAMHOMEBASE_UNAME="${UN:-$WORK/uname-arm}" FAMHOMEBASE_DRY_RUN=1 sh "$SCRIPT" $1 > "$WORK/out" 2>&1; }

runner "--version 0.5.6"; st=$?
check "a good version passes the checks (dry run), with a JSON line" "[ $st = 0 ] && grep -q '^{\"ts\":\".*\"component\":\"build-image\"' $WORK/out && grep -q 'env prod' $WORK/out"
runner "--version v0.5.6 --env staging --out $WORK/o"; st=$?
check "a leading v is accepted, the env and the output folder are taken" "[ $st = 0 ] && grep -q 'version 0.5.6, env staging' $WORK/out"
runner ""; st=$?
check "no version is refused" "[ $st != 0 ] && grep -q 'version is required' $WORK/out"
runner "--version latest"; st=$?
check "a junk version is refused" "[ $st != 0 ] && grep -q 'must look like' $WORK/out"
runner "--version 0.5.6 --env dev"; st=$?
check "an unknown environment is refused" "[ $st != 0 ] && grep -q 'not an environment' $WORK/out"
runner "--version 0.5.6 --extra-mb lots"; st=$?
check "a junk extra size is refused" "[ $st != 0 ] && grep -q 'whole number' $WORK/out"
runner "--version 0.5.6 --nope"; st=$?
check "an unknown option is refused" "[ $st != 0 ] && grep -q 'unknown option' $WORK/out"
runner "--version 0.5.6 --base-image $WORK/missing.img.xz"; st=$?
check "a base image that does not exist is refused" "[ $st != 0 ] && grep -q 'existing .img.xz' $WORK/out"
runner "--version 0.5.6 --hostname bad_name!"; st=$?
check "a junk host name is refused" "[ $st != 0 ] && grep -q 'not a host name' $WORK/out"
UN="$WORK/uname-x86" runner "--version 0.5.6"; st=$?
check "a machine that is not 64-bit ARM is refused, with what to do" "[ $st != 0 ] && grep -q '64-bit ARM' $WORK/out"
# a PATH of only the system tools the script uses plus the stubs, so a docker that happens to be installed on this machine can't leak in
mkdir -p "$WORK/tools"; for t in sed grep id date uname cut tr; do ln -s "$(command -v $t)" "$WORK/tools/$t"; done
mv "$WORK/bin/docker" "$WORK/docker.off"
st=0; PATH="$WORK/bin:$WORK/tools" FAMHOMEBASE_NO_ROOT=1 FAMHOMEBASE_UNAME="$WORK/uname-arm" FAMHOMEBASE_DRY_RUN=1 /bin/sh "$SCRIPT" --version 0.5.6 > "$WORK/out" 2>&1 || st=$?
check "a missing tool is named" "[ $st != 0 ] && grep -q 'docker is required' $WORK/out"
mv "$WORK/docker.off" "$WORK/bin/docker"
st=0; PATH="$WORK/bin:$PATH" FAMHOMEBASE_UNAME="$WORK/uname-arm" FAMHOMEBASE_DRY_RUN=1 sh "$SCRIPT" --version 0.5.6 > "$WORK/out" 2>&1 || st=$?
if [ "$(id -u)" -ne 0 ]; then check "without root it refuses, and says to use sudo" "[ $st != 0 ] && grep -q 'needs root' $WORK/out"; else ok "(running as root: the root check is skipped)"; fi
sh "$SCRIPT" --help > "$WORK/out" 2>&1
check "--help prints the usage" "grep -q 'build-image.sh --version' $WORK/out"

check "the image gets SSH host keys made at start, and none baked in" "grep -q 'ExecStartPre=/usr/bin/ssh-keygen -A' $SCRIPT && grep -q 'rm -f \"\$ROOT\"/etc/ssh/ssh_host_' $SCRIPT"
echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
