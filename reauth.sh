#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOKEN="request.token"
AUTH_FLAG="logs/AUTH-FAILURE.flag"
BACKUP=""

command -v youtubeuploader >/dev/null || { echo "youtubeuploader not found on PATH"; exit 1; }

DUMMY="$(mktemp -t reauth).mp4"
trap 'rm -f "$DUMMY"' EXIT
echo junk > "$DUMMY"

if [[ -f "$TOKEN" ]]; then
  BACKUP="$TOKEN.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TOKEN" "$BACKUP"
  rm "$TOKEN"
fi

echo "Browser will open. Authorize, then ignore the 400 'Media type' error."
youtubeuploader -filename "$DUMMY" -title test -privacy private || true

if [[ ! -f "$TOKEN" ]]; then
  [[ -n "$BACKUP" ]] && cp "$BACKUP" "$TOKEN"
  echo "Re-auth failed: no new $TOKEN written${BACKUP:+ (old token restored)}"
  exit 1
fi

rm -f "$AUTH_FLAG"
echo "Token refreshed."
