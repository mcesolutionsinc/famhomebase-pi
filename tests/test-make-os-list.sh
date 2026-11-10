#!/bin/sh
# Tests for tools/make-os-list.sh (the Raspberry Pi Imager list). Run: sh tests/test-make-os-list.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../tools/make-os-list.sh"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "NOT OK $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
printf 'not really an image' > "$WORK/img.xz"
SHA=$(printf 'abc' | sha256sum | cut -d' ' -f1)
run() { sh "$SCRIPT" --image "$WORK/img.xz" --extract-size 3078619136 --extract-sha256 "$SHA" --url https://example.test/a.img.xz --version 0.5.9 --out "$WORK/list.json" "$@" > "$WORK/out" 2>&1; }

run; st=$?
J="$WORK/list.json"
check "a good run writes the file, with a JSON log line" "[ $st = 0 ] && [ -s $J ] && grep -q '^{\"ts\":\".*\"component\":\"make-os-list\"' $WORK/out"
check "the entry has the fields Imager needs and the init_format that turns customisation on" "grep -q '\"init_format\": \"cloudinit-rpi\"' $J && grep -q '\"extract_size\": 3078619136' $J && grep -q '\"extract_sha256\": \"$SHA\"' $J && grep -q '\"url\": \"https://example.test/a.img.xz\"' $J && grep -q '\"image_download_size\": 19' $J"
check "the download size and checksum are those of the real file" "grep -q \"\\\"image_download_sha256\\\": \\\"\$(sha256sum $WORK/img.xz | cut -d' ' -f1)\\\"\" $J"
check "it offers the Pi 4 and the Pi 5, in 64-bit" "grep -q '\"devices\": \\[\"pi5-64bit\", \"pi4-64bit\"\\]' $J"
check "the prod entry is plainly named, with no STAGING words" "grep -q '\"name\": \"FamHomeBase display 0.5.9\"' $J && ! grep -qi staging $J"
if command -v python3 >/dev/null 2>&1; then check "the file is valid JSON with one entry" "python3 -c \"import json,sys; d=json.load(open('$J')); assert len(d['os_list'])==1\""; else ok "(python3 missing: JSON check skipped)"; fi
run --env staging; st=$?
check "a staging entry says it is a test build, not for customers" "[ $st = 0 ] && grep -q 'STAGING, for testing' $J && grep -q 'Not for customers' $J"
run --version 1.2; st=$?
check "a bad version is refused" "[ $st != 0 ] && grep -q 'must look like' $WORK/out"
run --extract-size abc; st=$?
check "a size that is not a number is refused" "[ $st != 0 ] && grep -q 'size in bytes' $WORK/out"
run --extract-sha256 XYZ; st=$?
check "a checksum that is not 64 hex characters is refused" "[ $st != 0 ] && grep -q '64-character' $WORK/out"
run --url notanaddress; st=$?
check "a url that is not an address is refused" "[ $st != 0 ] && grep -q 'must be an address' $WORK/out"
run --env dev; st=$?
check "an unknown environment is refused" "[ $st != 0 ] && grep -q 'prod or staging' $WORK/out"
sh "$SCRIPT" --image "$WORK/missing.xz" > "$WORK/out" 2>&1; st=$?
check "a missing image file is refused" "[ $st != 0 ] && grep -q 'existing .img.xz' $WORK/out"
run --bogus; st=$?
check "an unknown option is refused" "[ $st != 0 ] && grep -q 'unknown option' $WORK/out"

run --url /Users/me/a.img.xz; st=$?
check "a plain path as the url is refused (Imager rejects it: no host part)" "[ $st != 0 ] && grep -q 'file:///' $WORK/out"
run --url file:///Users/me/a.img.xz; st=$?
check "a file:/// address is accepted for a local test" "[ $st = 0 ] && grep -q '\"url\": \"file:///Users/me/a.img.xz\"' $WORK/list.json"
run --url 'https://x.example.org/a"b.img.xz'; st=$?
check "an address with a quote (which would break the JSON) is refused" "[ $st != 0 ] && grep -q 'must not contain' $WORK/out"
run --url 'https://x.example.org/a b.img.xz'; st=$?
check "an address with a space is refused" "[ $st != 0 ] && grep -q 'must not contain' $WORK/out"
touch -d '2026-11-01 12:00' "$WORK/img.xz"; run; st=$?
check "the release date is the image's date, not the day the list was written" "[ $st = 0 ] && grep -q '\"release_date\": \"2026-11-01\"' $WORK/list.json"
echo "$n tests, $fail failed"; [ "$fail" -eq 0 ]
