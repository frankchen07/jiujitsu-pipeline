#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_DIR="$SCRIPT_DIR/launchagents"
LABELS=("com.frankchen.jiujitsu.ingest" "com.frankchen.jiujitsu.convert" "com.frankchen.jiujitsu.upload")

uninstall() {
  for label in "${LABELS[@]}"; do
    local dest="$LAUNCH_AGENTS_DIR/${label}.plist"
    if launchctl list "$label" &>/dev/null; then
      launchctl unload "$dest" 2>/dev/null || true
      echo "  [unloaded] $label"
    fi
    if [[ -L "$dest" || -f "$dest" ]]; then
      rm -f "$dest"
      echo "  [removed] $dest"
    fi
  done
  echo "Uninstall complete."
}

install() {
  mkdir -p "$LAUNCH_AGENTS_DIR"
  mkdir -p "$SCRIPT_DIR/logs"

  for label in "${LABELS[@]}"; do
    local src="$PLIST_DIR/${label}.plist"
    local dest="$LAUNCH_AGENTS_DIR/${label}.plist"

    [[ -f "$src" ]] || { echo "ERROR: missing $src"; exit 1; }

    # Stamp the real script dir into a temp copy (plists need absolute paths)
    local tmp
    tmp=$(mktemp /tmp/${label}.XXXXXX.plist)
    sed "s|PLACEHOLDER_SCRIPT_DIR|${SCRIPT_DIR}|g" "$src" > "$tmp"

    # Unload first if already running
    if launchctl list "$label" &>/dev/null; then
      launchctl unload "$dest" 2>/dev/null || true
    fi

    cp "$tmp" "$dest"
    rm -f "$tmp"
    launchctl load "$dest"
    echo "  [loaded] $label"
  done

  echo ""
  echo "Agents installed. Schedule:"
  echo "  ingest  → 9:00pm daily  (moves IMG_####.MOV/MP4 from ~/Downloads to rolling/)"
  echo "  convert → 3:00am daily  (runs process.sh --convert-only)"
  echo "  upload  → 10:00am daily (runs process.sh --upload-only)"
  echo ""
  echo "Verify with: launchctl list | grep jiujitsu"
  echo "Test run:    launchctl start com.frankchen.jiujitsu.ingest"
}

case "${1:-install}" in
  --uninstall) uninstall ;;
  install|*)   install ;;
esac
