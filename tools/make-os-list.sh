#!/bin/sh
# Writes the Raspberry Pi Imager "repository" file (JSON, the format Imager 2.x reads) that offers a FamHomeBase display image. With this list
# Imager shows its customisation screen (Wi-Fi, user, SSH key, host name) for our image: it only does that for images whose entry says how to
# apply them (`init_format`); a plain "Use custom" file gets none. The fields follow the official Raspberry Pi OS Lite entry.
#   sh tools/make-os-list.sh --image FILE.img.xz --extract-size N --extract-sha256 HEX --url URL --version X.Y.Z --env prod|staging --out FILE
set -u

jlog() { printf '{"ts":"%s","level":"%s","component":"make-os-list","msg":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }
die() { jlog error "$*"; exit 1; }

IMAGE=""; SIZE=""; SHA=""; URL=""; VERSION=""; ENVNAME=prod; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image) [ $# -ge 2 ] && [ -f "$2" ] || die "--image needs an existing .img.xz file"; IMAGE=$2; shift ;;
    --extract-size) [ $# -ge 2 ] || die "--extract-size needs a number"; SIZE=$2; shift ;;
    --extract-sha256) [ $# -ge 2 ] || die "--extract-sha256 needs a checksum"; SHA=$2; shift ;;
    --url) [ $# -ge 2 ] || die "--url needs the address the image will be downloaded from"; URL=$2; shift ;;
    --version) [ $# -ge 2 ] || die "--version needs X.Y.Z"; VERSION=$2; shift ;;
    --env) [ $# -ge 2 ] || die "--env needs prod or staging"; ENVNAME=$2; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a file name"; OUT=$2; shift ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[ -n "$IMAGE" ] || die "--image is required"
echo "$SIZE" | grep -Eq '^[0-9]+$' || die "--extract-size must be the size in bytes of the uncompressed image"
echo "$SHA" | grep -Eq '^[0-9a-f]{64}$' || die "--extract-sha256 must be a 64-character lower-case hex checksum of the uncompressed image"
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "--version must look like 0.5.9"
case "$ENVNAME" in prod|staging) ;; *) die "--env must be prod or staging" ;; esac
case "$URL" in https://*|http://*|file:///*) ;; *) die "--url must be an address: https://..., or file:///full/path for a local test (a plain path gives Imager 'No host part in the url')" ;; esac
[ -n "$OUT" ] || die "--out is required"

DOWNLOAD_SIZE=$(wc -c < "$IMAGE" | tr -d ' ')
DOWNLOAD_SHA=$(sha256sum "$IMAGE" | cut -d' ' -f1)
case "$ENVNAME" in
  prod) NAME="FamHomeBase display $VERSION"; WHAT="The FamHomeBase wall display: boots to a pairing code. Set Wi-Fi, a user and an SSH key in the customisation screen." ;;
  *) NAME="FamHomeBase display $VERSION (STAGING, for testing)"; WHAT="A TEST build that talks to the staging cloud. Not for customers." ;;
esac

cat > "$OUT" <<JSON_EOF
{
  "os_list": [
    {
      "name": "$NAME",
      "description": "$WHAT",
      "url": "$URL",
      "extract_size": $SIZE,
      "extract_sha256": "$SHA",
      "image_download_size": $DOWNLOAD_SIZE,
      "image_download_sha256": "$DOWNLOAD_SHA",
      "release_date": "$(date -u +%Y-%m-%d)",
      "init_format": "cloudinit-rpi",
      "devices": ["pi5-64bit", "pi4-64bit"],
      "capabilities": []
    }
  ]
}
JSON_EOF
jlog info "wrote the Imager list $OUT"
