#!/bin/sh
# Settings put on the boot drive: if a file `famhomebase.env` is there (the part of the card any computer can edit), apply the two settings it may
# carry to the display's real settings file, then delete it. Started by famhomebase-bootconfig.service (host-setup.sh) before the display starts, only
# when the file exists. It is how one prod image is pointed at staging for testing: no file means the image's own settings (prod).
#   FAMHOMEBASE_ENV=staging                                    prod or staging (the address below is filled in when it is left out)
#   FAMHOMEBASE_API_URL=https://staging.famhomebase.mc-esolutions.ca    https://host, no path
# Anything else in the file is ignored. A bad value leaves the file where it is, says so in the log, and changes nothing. Always exits 0: a bad
# file must never stop a boot.
set -u

jlog() { printf '{"ts":"%s","level":"%s","component":"bootconfig","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }

BOOT="${FAMHOMEBASE_BOOT_DIR:-/boot/firmware}"
ETC="${FAMHOMEBASE_ETC_DIR:-/etc/famhomebase}"
SRC="$BOOT/famhomebase.env"
DST="$ETC/famhomebase.env"
PROD_URL=https://famhomebase.mc-esolutions.ca
STAGING_URL=https://staging.famhomebase.mc-esolutions.ca

[ -f "$SRC" ] || exit 0

# a value as written in the file: a Windows line ending and one pair of quotes around it are not part of it; the last line for a key wins
getsrc() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$SRC" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -e "s/^\"\\(.*\\)\"\$/\\1/" -e "s/^'\\(.*\\)'\$/\\1/"; }

ENVNAME=$(getsrc FAMHOMEBASE_ENV)
API=$(getsrc FAMHOMEBASE_API_URL)

# other settings are not for this file: said once, then ignored (the names only: a value might hold anything)
others=$(tr -d '\r' < "$SRC" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | grep -vxE 'FAMHOMEBASE_ENV|FAMHOMEBASE_API_URL' | sort -u | paste -sd, -)
[ -z "$others" ] || jlog warn "ignored settings this file does not take: $others"

case "$ENVNAME" in
  ''|prod|staging) ;;
  *) jlog error "FAMHOMEBASE_ENV in $SRC must be prod or staging: nothing was changed, the file stays"; exit 0 ;;
esac
if [ -n "$API" ] && ! echo "$API" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?$'; then
  jlog error "FAMHOMEBASE_API_URL in $SRC must be https://host with no path: nothing was changed, the file stays"; exit 0
fi
if [ -z "$ENVNAME" ] && [ -z "$API" ]; then
  jlog warn "$SRC has neither FAMHOMEBASE_ENV nor FAMHOMEBASE_API_URL: nothing to apply, the file stays"; exit 0
fi
if [ ! -f "$DST" ]; then
  jlog error "there is no settings file $DST yet (is the display installed?): nothing was changed, the file stays"; exit 0
fi
if [ -z "$API" ]; then
  case "$ENVNAME" in staging) API=$STAGING_URL ;; prod) API=$PROD_URL ;; esac
fi

set_env() { # key, value
  if grep -q "^$1=" "$DST"; then
    sed "s|^$1=.*|$1=$2|" "$DST" > "$DST.new" && mv "$DST.new" "$DST"
  else
    printf '%s=%s\n' "$1" "$2" >> "$DST"
  fi
}
[ -z "$ENVNAME" ] || set_env FAMHOMEBASE_ENV "$ENVNAME"
[ -z "$API" ] || set_env FAMHOMEBASE_API_URL "$API"
jlog info "applied ${ENVNAME:+environment $ENVNAME }${API:+cloud $API} from the boot drive"

rm -f "$SRC" || jlog warn "could not delete $SRC: it will be applied again at the next boot (harmless)"
exit 0
