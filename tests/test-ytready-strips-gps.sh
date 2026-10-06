#!/usr/bin/env bash
# Runs process.sh --convert-only and --teaching-only against a synthetic GPS-tagged clip
# in a throwaway copy of the repo, then checks:
#   - GPS still drives the filename (location code in the name)
#   - ytready/ copies (what gets uploaded to YouTube) carry no location metadata
#   - sstready/ archive copies keep it
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp "$REPO/process.sh" "$WORK/"
# Keep test output off the real external archive volume
sed -i '' "s|^SST_VOLUME_BASE=.*|SST_VOLUME_BASE=\"$WORK/volume\"|" "$WORK/process.sh"
mkdir -p "$WORK/rolling" "$WORK/teaching"
touch "$WORK/client_secrets.json" "$WORK/request.token"

make_clip() {
  # San Jose gym coords, Tuesday 7pm PT (not a teaching slot)
  ffmpeg -y -loglevel error -f lavfi -i testsrc=d=1:s=640x360 -f lavfi -i sine=d=1 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags use_metadata_tags \
    -metadata "com.apple.quicktime.location.ISO6709=+37.3644-121.8973+010.000/" \
    -metadata "location=+37.3644-121.8973/" \
    -metadata "creation_time=2026-10-07T02:00:00Z" \
    "$1"
}
make_clip "$WORK/rolling/IMG_0001.mov"
make_clip "$WORK/teaching/IMG_0002.mov"

(cd "$WORK" && bash "$WORK/process.sh" --convert-only >"$WORK/convert.log" 2>&1) || { cat "$WORK/convert.log"; exit 1; }
(cd "$WORK" && bash "$WORK/process.sh" --teaching-only >"$WORK/teaching.log" 2>&1) || { cat "$WORK/teaching.log"; exit 1; }

has_location() {
  ffprobe -v quiet -show_entries format_tags:stream_tags -of default "$1" | grep -qi "location\|ISO6709"
}

fail=0
shopt -s nullglob
yt=("$WORK"/ytready/*.mov)
sst=("$WORK"/sstready/*.mov "$WORK"/sstready/.uncopied/*.mov "$WORK"/volume/*/*.mov "$WORK"/volume/*.mov)
[[ ${#yt[@]} -ge 2 ]] || { echo "FAIL: expected >=2 ytready files, got ${#yt[@]}"; ls -R "$WORK"; exit 1; }
[[ ${#sst[@]} -ge 1 ]] || { echo "FAIL: expected sstready archive output"; ls -R "$WORK"; exit 1; }

ls "$WORK"/ytready | grep -q -- "-10psj-" && echo "PASS: GPS still drives filename (10psj)" \
  || { echo "FAIL: no 10psj in ytready names"; fail=1; }
for f in "${yt[@]}"; do
  if has_location "$f"; then echo "FAIL: location metadata in $(basename "$f")"; fail=1
  else echo "PASS: no location in $(basename "$f")"; fi
done
for f in "${sst[@]}"; do
  if has_location "$f"; then echo "PASS: archive keeps location in $(basename "$f")"
  else echo "FAIL: archive lost location in $(basename "$f")"; fail=1; fi
done
exit $fail
