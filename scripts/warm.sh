#!/bin/sh
# Reads the browser, the screen service (cage) and the graphics drivers once, so they are in the system's file cache when the kiosk starts.
# A browser started cold from an SD card needs about 6 more seconds than one whose files were just read, and those seconds were a dark
# screen after the boot splash. This runs during the boot (the splash covers it) at the lowest priority: it only uses time the disk and
# the CPU would not use otherwise, and it never delays or fails the boot. Run by famhomebase-warm.service (see host-setup.sh).
#
#   FAMHOMEBASE_WARM_SKIP_MB   skip the read when less than this much memory is free (default 700; the files are about 500 MB)
set -u

jlog() { printf '{"ts":"%s","level":"%s","component":"warm","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }

MEMINFO=${FAMHOMEBASE_MEMINFO:-/proc/meminfo}
NEED=${FAMHOMEBASE_WARM_SKIP_MB:-700}
case "$NEED" in ''|*[!0-9]*) NEED=700 ;; esac
AVAIL_MB=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' "$MEMINFO" 2>/dev/null)
case "$AVAIL_MB" in ''|*[!0-9]*) AVAIL_MB=0 ;; esac
if [ "$AVAIL_MB" -lt "$NEED" ]; then jlog info "not enough free memory to keep the browser's files cached ($AVAIL_MB MB free): skipped"; exit 0; fi

START=$(date +%s)
n=0
for dir in ${FAMHOMEBASE_WARM_DIRS:-/usr/lib/chromium /usr/lib/chromium-browser}; do
  [ -d "$dir" ] || continue
  find "$dir" -type f -exec cat {} + >/dev/null 2>&1
  n=$((n + 1))
done
for f in "${FAMHOMEBASE_WARM_CAGE:-/usr/bin/cage}" ${FAMHOMEBASE_WARM_DRI:-/usr/lib/*/dri/vc4_dri.so /usr/lib/*/dri/v3d_dri.so /usr/lib/*/dri/kms_swrast_dri.so}; do
  [ -f "$f" ] && { cat "$f" >/dev/null 2>&1; n=$((n + 1)); }
done
jlog info "read $n browser and graphics locations into the file cache in $(($(date +%s) - START))s"
exit 0
