#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLING="$SCRIPT_DIR/rolling"
DOWNLOADS="$HOME/Downloads"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_DATE=$(TZ="America/Los_Angeles" date +%Y-%m-%d)
INGEST_LOG="$LOG_DIR/${LOG_DATE}-ingest.log"

mkdir -p "$LOG_DIR" "$ROLLING"

moved=0
skipped_transferring=0
skipped_duplicate=0

log_ingest() {
  local action="$1" src="$2" dest="${3:-}"
  printf '%s\t%s\t%s\t%s\n' \
    "$(TZ="America/Los_Angeles" date '+%Y-%m-%d %H:%M:%S %Z')" \
    "$action" "$src" "$dest" >> "$INGEST_LOG"
}

while IFS= read -r -d '' f; do
  bname=$(basename "$f")
  dest="$ROLLING/$bname"

  # Skip files modified in the last 60 seconds — may still be mid-AirDrop
  age=$(( $(date +%s) - $(stat -f %m "$f") ))
  if [[ $age -lt 60 ]]; then
    echo "  [skip-transferring] $bname (modified ${age}s ago)"
    log_ingest "skip-transferring" "$f" ""
    skipped_transferring=$(( skipped_transferring + 1 ))
    continue
  fi

  # Skip if same basename already in rolling/
  if [[ -e "$dest" ]]; then
    echo "  [skip-duplicate] $bname"
    log_ingest "skip-duplicate" "$f" "$dest"
    skipped_duplicate=$(( skipped_duplicate + 1 ))
    continue
  fi

  mv "$f" "$dest"
  log_ingest "moved" "$f" "$dest"
  echo "  [moved] $bname"
  moved=$(( moved + 1 ))
done < <(find "$DOWNLOADS" -maxdepth 1 \( -iname "IMG_[0-9][0-9][0-9][0-9].MOV" -o -iname "IMG_[0-9][0-9][0-9][0-9].MP4" \) -print0 2>/dev/null)

echo "Ingest complete: $moved moved, $skipped_transferring still-transferring, $skipped_duplicate duplicates"
