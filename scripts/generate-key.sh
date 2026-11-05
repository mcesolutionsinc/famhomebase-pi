#!/bin/sh
# Creates the configstore's encryption key at ./secrets/dashboard.key, if (and only if) it doesn't already
# exist — see issue #28's key-handling requirements. Overwriting an existing key would orphan every already-
# encrypted account's secrets (they'd become permanently undecryptable), so this refuses to touch one that's
# already there rather than assuming that's what you meant.
#
# Run from the repo checkout that has the docker-compose file referencing ./secrets/dashboard.key, e.g.:
#   ./configstore/scripts/generate-key.sh
set -eu

KEY_PATH="${1:-./secrets/dashboard.key}"

if [ -f "$KEY_PATH" ]; then
  echo "Key already exists at $KEY_PATH — leaving it alone. Delete it yourself first if you really mean to replace it (this orphans every currently-stored account's secrets)." >&2
  exit 1
fi

mkdir -p "$(dirname "$KEY_PATH")"
# 32 raw random bytes, not hex/base64 text — see configstore/src/crypto.ts's loadKey, which reads the file
# directly as the AES-256 key.
if command -v openssl >/dev/null 2>&1; then
  openssl rand 32 > "$KEY_PATH"
else
  node -e "require('fs').writeFileSync(process.argv[1], require('crypto').randomBytes(32))" "$KEY_PATH"
fi
chmod 600 "$KEY_PATH"

echo "Generated a new key at $KEY_PATH (chmod 600). Back this up separately from ./data — see issue #28: losing it means reconnecting calendars, not losing the rest of the config."
