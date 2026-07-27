#!/bin/bash
set -euo pipefail

# --- Prevent macOS idle/disk sleep for the duration of this script ---
if [[ -z "${CAFFEINATED:-}" ]]; then
  export CAFFEINATED=1
  exec caffeinate -i "$0" "$@"
fi

# === JJ Video Processing Pipeline ===
#
# Input structure:
#   jjvideos/rolling/   ← drop zone: GPS auto-detects 10psm/10psj, fallback to 10p
#   jjvideos/teaching/  ← teaching class recordings (both outputs keep audio)
#
# Rolling pipeline per file:
#   1. GPS detection → loc (10psm, 10psj, or 10p)
#   2. Read creation_time in UTC, convert to America/Los_Angeles, then derive canonical name:
#      YYYYMMDD-dayofweektimeofday-LOC-rolling-footage-viewN.mov
#   3. Compress with audio → sstready/ (archive)
#   4. Strip audio → ytready/ (upload)
#   5. If loc=10psm + Mon/Wed/Fri + 05:45-06:30 PST → also create teaching copies:
#      - sstready/ as YYYYMMDD-teaching-class-fc-N.mov (with audio)
#      - ytready/  as YYYYMMDD-teaching-class-fc-N-ytready.mov (with audio)
#   6. Upload to YouTube with playlist routing
#   7. After ALL conversions verified: source → .trash/, sstready → .uncopied/
#   8. After confirmed upload: ytready → .trash/
#
# Teaching pipeline per file:
#   1. Compress with audio → sstready/YYYYMMDD-teaching-class-fc-N.mov
#   2. cp sstready → ytready/YYYYMMDD-teaching-class-fc-N-ytready.mov (no re-encode, keeps audio)
#   3. Upload → public + PLAYLIST_TEACHING
#
# Rules:
# - Rolling videos are unlisted + location playlist (10psj or 10psm).
# - Teaching videos are public + teaching playlist.
# - Every rename is recorded in a dated ledger for backtracking.
#
# Time of day in PST/PDT local time:
#   morning = 04:00-11:59
#   afternoon = 12:00-17:59
#   night = 18:00-23:59
# Views: auto-numbered by creation time within same date+timeofday+location session

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSTREADY="$SCRIPT_DIR/sstready"
SST_UNCOPIED="$SSTREADY/.uncopied"
SST_VOLUME_BASE="/Volumes/sst7-1/create/frankthetankjj"
YTREADY="$SCRIPT_DIR/ytready"
TRASH="$SCRIPT_DIR/.trash"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_DATE=$(TZ="America/Los_Angeles" date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/${LOG_DATE}-process.md"
RENAME_LEDGER="$LOG_DIR/${LOG_DATE}-renames.tsv"

mkdir -p "$SSTREADY" "$SST_UNCOPIED" "$YTREADY" "$TRASH" "$LOG_DIR"
touch "$RENAME_LEDGER"

# CONFIGURE: Set GPS coordinates for each gym location and detection radius.
# Add or remove GPS_LOC_* pairs to match your locations; use Google Maps to get lat/lon.
# Gym coordinates for GPS auto-detection (plus codes: HM8R+M2 SanMateo, 9473+Q4 SanJose)
GPS_10PSM_LAT=37.5666; GPS_10PSM_LON=-122.3102
GPS_10PSJ_LAT=37.3644; GPS_10PSJ_LON=-121.8973
GPS_RADIUS_KM=1.0

# --- Upload state: daily quota management ---
UPLOAD_STATE="$LOG_DIR/upload-state.tsv"
MAX_DAILY_UPLOADS="${YT_DAILY_LIMIT:-30}"
QUOTA_EXCEEDED=false
touch "$UPLOAD_STATE"

UPLOAD_ONLY=false
CONVERT_ONLY=false
TEACHING_ONLY=false
LOC_FILTER=""  # e.g. "10psj" — only collect from that subdirectory
FILE_LIMIT=0   # 0 = no limit; N = process only N oldest files

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upload-only)   UPLOAD_ONLY=true ;;
    --convert-only)  CONVERT_ONLY=true ;;
    --teaching-only) TEACHING_ONLY=true ;;
    --loc)           LOC_FILTER="${2:-}"; shift ;;
    --limit)         FILE_LIMIT="${2:-0}"; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
  shift
done

# --- Logging (logs/YYYY-MM-DD-process.md) ---
{
  echo "## Run: $(TZ=\"America/Los_Angeles\" date '+%Y-%m-%d %H:%M:%S %Z')"
  echo ""
} >> "$LOG_FILE"

# --- Helper functions ---

day_name() {
  case "$1" in
    1) echo "monday" ;; 2) echo "tuesday" ;; 3) echo "wednesday" ;;
    4) echo "thursday" ;; 5) echo "friday" ;; 6) echo "saturday" ;; 7) echo "sunday" ;;
  esac
}

time_of_day() {
  local h=$((10#$1))
  if [[ $h -ge 4 && $h -lt 12 ]]; then echo "morning"
  elif [[ $h -ge 12 && $h -lt 18 ]]; then echo "afternoon"
  else echo "night"
  fi
}

get_epoch() {
  local input_file="$1"
  local ts
  ts=$(ffprobe -v quiet -show_entries format_tags=creation_time \
    -of csv=p=0 "$input_file" 2>/dev/null | head -1)
  if [[ -z "$ts" ]]; then echo ""; return; fi
  local clean
  clean=$(echo "$ts" | sed 's/\.[0-9]*Z$//' | sed 's/Z$//')
  date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null || echo ""
}

get_gps_loc() {
  local input_file="$1"
  local raw
  raw=$(ffprobe -v quiet -show_entries "format_tags=com.apple.quicktime.location.ISO6709" \
    -of csv=p=0 "$input_file" 2>/dev/null | head -1)
  [[ -z "$raw" ]] && echo "" && return

  # Parse ISO 6709: +37.5666-122.3102+003.145/ → lat, lon
  local lat lon
  lat=$(echo "$raw" | grep -oE '^[+-][0-9]+\.[0-9]+')
  lon=$(echo "$raw" | grep -oE '[+-][0-9]+\.[0-9]+' | sed -n '2p')
  [[ -z "$lat" || -z "$lon" ]] && echo "" && return

  # Haversine distance in awk — returns closest gym within GPS_RADIUS_KM, or empty
  awk -v lat="$lat" -v lon="$lon" \
    -v lat_m="$GPS_10PSM_LAT" -v lon_m="$GPS_10PSM_LON" \
    -v lat_j="$GPS_10PSJ_LAT" -v lon_j="$GPS_10PSJ_LON" \
    -v r="$GPS_RADIUS_KM" \
    'function hav(la1,lo1,la2,lo2,   R,pi,dlat,dlon,a,c) {
       R=6371; pi=3.14159265358979
       dlat=(la2-la1)*pi/180; dlon=(lo2-lo1)*pi/180
       a=sin(dlat/2)^2+cos(la1*pi/180)*cos(la2*pi/180)*sin(dlon/2)^2
       c=2*atan2(sqrt(a),sqrt(1-a)); return R*c
     }
     BEGIN {
       dm=hav(lat,lon,lat_m,lon_m)
       dj=hav(lat,lon,lat_j,lon_j)
       if (dm<=r) print "10psm"
       else if (dj<=r) print "10psj"
       else print ""
     }'
}

log_rename() {
  local src="$1" dest="$2"
  printf '%s\t%s\t%s\n' "$(TZ=\"America/Los_Angeles\" date '+%Y-%m-%d %H:%M:%S %Z')" "$src" "$dest" >> "$RENAME_LEDGER"
}

move_to_trash() {
  local file="$1"
  local bname
  bname=$(basename "$file")
  local dest="$TRASH/$bname"
  [[ -e "$dest" ]] && dest="$TRASH/${bname%.mov}-$(date +%s).mov"
  mv "$file" "$dest"
}

try_copy_to_volume() {
  local file="$1"
  local bname
  bname=$(basename "$file")
  local vol_subdir="rolling"
  [[ "$bname" == *"teaching"* ]] && vol_subdir="teaching"
  local dest_dir="$SST_VOLUME_BASE/$vol_subdir"

  if [[ ! -d "$SST_VOLUME_BASE" ]]; then
    echo "  [volume] Drive not mounted — $bname stays in .uncopied/ for next run"
    return 1
  fi

  mkdir -p "$dest_dir"
  if cp "$file" "$dest_dir/$bname"; then
    echo "  [volume] Copied to $dest_dir/$bname"
    return 0
  else
    echo "  [volume] Copy failed — $bname stays in .uncopied/ for next run"
    return 1
  fi
}

# Returns 0 if file is readable, duration >= 60s, audio presence matches want_audio ("yes"|"no"),
# output duration is within 5% of input_dur (optional), and full decode scan finds no errors.
verify_output() {
  local f="$1" want_audio="$2" input_dur="${3:-}"
  local dur has_audio
  dur=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)
  [[ -z "$dur" || "$dur" == "N/A" ]] && return 1
  # Truncate to integer seconds (bash can't do float comparison)
  local dur_secs="${dur%%.*}"
  [[ "${dur_secs:-0}" -lt 60 ]] && return 1
  # If input duration provided, verify output is within 5% (catches truncated encodes)
  if [[ -n "$input_dur" && "$input_dur" != "N/A" ]]; then
    local in_secs="${input_dur%%.*}"
    local min_secs=$(( in_secs * 95 / 100 ))
    [[ "${dur_secs:-0}" -lt "$min_secs" ]] && return 1
  fi
  has_audio=$(ffprobe -v error -select_streams a:0 \
              -show_entries stream=codec_type \
              -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)
  if [[ "$want_audio" == "yes" && -z "$has_audio" ]]; then return 1; fi
  if [[ "$want_audio" == "no"  && -n "$has_audio" ]]; then return 1; fi
  # Full decode scan — catches codec errors and truncation that duration alone misses
  ffmpeg -v fatal -i "$f" -f null - 2>/dev/null || return 1
  return 0
}

daily_upload_count() {
  grep -c "^$(TZ="America/Los_Angeles" date +%Y-%m-%d)" "$UPLOAD_STATE" 2>/dev/null || true
}

already_uploaded() {
  local name="$1"
  grep -qF $'\t'"$name"$'\t' "$UPLOAD_STATE" 2>/dev/null
}

process_teaching_folder() {
  echo "=== Teaching folder mode ==="
  shopt -s nullglob
  local files=("$SCRIPT_DIR/teaching"/*.MOV "$SCRIPT_DIR/teaching"/*.mov)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No teaching files found in teaching/."
    return 0
  fi

  # Build epoch|path pairs, skip files with no creation_time, then sort oldest-first
  local ep_pairs=()
  for f in "${files[@]}"; do
    local ep
    ep=$(get_epoch "$f")
    [[ -z "$ep" ]] && { echo "WARN: No creation_time for $(basename "$f"), skipping."; continue; }
    ep_pairs+=("${ep}|${f}")
  done

  if [[ ${#ep_pairs[@]} -eq 0 ]]; then
    echo "No teaching files had readable creation_time. Nothing to process."
    return 0
  fi

  local sorted_pairs=()
  while IFS= read -r line; do
    sorted_pairs+=("$line")
  done < <(printf '%s\n' "${ep_pairs[@]}" | sort -t'|' -k1,1n)

  # Per-date session counter — multiple teaching files on same day get -1, -2, ...
  # Files are pre-sorted oldest-first so same-date files are contiguous; no assoc array needed.
  local _prev_date="" session_num=0

  for pair in "${sorted_pairs[@]}"; do
    local ep="${pair%%|*}"
    local input_file="${pair#*|}"
    local filename canonical_base sst_out yt_out datestamp
    filename=$(basename "$input_file")

    datestamp=$(TZ="America/Los_Angeles" date -r "$ep" +%Y%m%d)
    if [[ "$datestamp" != "$_prev_date" ]]; then
      _prev_date="$datestamp"
      session_num=0
    fi
    session_num=$(( session_num + 1 ))

    canonical_base="${datestamp}-teaching-class-fc-${session_num}"
    sst_out="$SSTREADY/${canonical_base}.mov"
    yt_out="$YTREADY/${canonical_base}-ytready.mov"

    echo "=== Teaching Processing: $filename (session ${session_num}) ==="

    if [[ -f "$sst_out" ]]; then
      echo "  [sstready] Already exists, skipping."
    else
      echo "  [sstready] Compressing with audio..."
      ffmpeg -y -loglevel error -hide_banner -nostats -i "$input_file" \
        -c:v libx264 -profile:v high -level 4.1 -preset veryfast -crf 23 \
        -vf "scale=1280:720,fps=30" \
        -b:v 8083k \
        -c:a aac -b:a 191k -ar 44100 \
        -movflags +faststart \
        "$sst_out"
      log_rename "$input_file" "$sst_out"
    fi

    if [[ -f "$yt_out" ]]; then
      echo "  [ytready] Already exists, skipping."
    elif [[ -f "$sst_out" ]]; then
      echo "  [ytready] Copying audio archive to ytready naming..."
      cp "$sst_out" "$yt_out"
      log_rename "$sst_out" "$yt_out"
    fi

    if [[ -f "$sst_out" && -f "$yt_out" ]]; then
      echo "  [verify] Checking teaching outputs..."
      local verify_ok=true
      if ! verify_output "$sst_out" "yes"; then
        echo "  [verify] FAIL: sstready output corrupt or missing audio — skipping cleanup"
        verify_ok=false
      else
        echo "  [verify] OK: sstready has audio"
      fi
      if ! verify_output "$yt_out" "yes"; then
        echo "  [verify] FAIL: ytready output corrupt or missing audio — skipping cleanup"
        verify_ok=false
      else
        echo "  [verify] OK: ytready has audio"
      fi
      if $verify_ok; then
        echo "  [cleanup] Verified — trashing source, archiving sstready"
        move_to_trash "$input_file"
        mv "$sst_out" "$SST_UNCOPIED/"
        log_rename "$sst_out" "$SST_UNCOPIED/$(basename "$sst_out")"
        if try_copy_to_volume "$SST_UNCOPIED/$(basename "$sst_out")"; then
          rm "$SST_UNCOPIED/$(basename "$sst_out")"
        fi
      else
        echo "  [cleanup] Verification FAILED — source kept, sstready kept for inspection"
      fi
    elif [[ -f "$sst_out" ]]; then
      echo "  [warn] sst_out exists but yt_out missing — skipping cleanup"
    fi
  done
  echo "=== Teaching folder done ==="
}

yt_upload() {
  local file="$1" title="$2" privacy="$3" playlist_id="${4:-}"
  local meta="$SCRIPT_DIR/.meta-tmp.json"
  local bname
  bname=$(basename "$file" .mov)

  # Skip if already recorded in state (any date)
  if already_uploaded "$bname"; then
    echo "  [upload] Already uploaded, skipping: $bname"
    return 4
  fi

  # Enforce daily cap before attempting
  local today_count
  today_count=$(daily_upload_count)
  if [[ $today_count -ge $MAX_DAILY_UPLOADS ]]; then
    echo "  [upload] Daily limit reached ($today_count/$MAX_DAILY_UPLOADS). Override: YT_DAILY_LIMIT=N. Run again tomorrow."
    return 2
  fi

  cat > "$meta" <<EOF
{
  "title": "${title}",
  "description": "",
  "selfDeclaredMadeForKids": false
}
EOF

  local playlist_flag=""
  if [[ -n "$playlist_id" ]]; then
    playlist_flag="-playlistID $playlist_id"
  fi

  echo "  [upload] '${title}' → ${privacy}${playlist_id:+ + playlist}..."
  echo "uploading | $(TZ=\"America/Los_Angeles\" date '+%Y-%m-%d %H:%M %Z') | ${bname} | ${privacy}" > "$PROGRESS_FILE"
  local result
  result=$(youtubeuploader \
    -filename "$file" \
    -cache "$YT_TOKEN" \
    -secrets "$YT_SECRETS" \
    -metaJSON "$meta" \
    -privacy "$privacy" \
    -notify=false \
    -quiet \
    $playlist_flag 2>&1) || true

  rm -f "$meta"

  if echo "$result" | grep -q "Video ID:"; then
    local vid
    vid=$(echo "$result" | grep "Video ID:" | sed 's/.*Video ID: //')
    echo "  [upload] Success! ID: ${vid} → https://studio.youtube.com/video/${vid}/edit"
    printf '%s\t%s\t%s\n' "$(TZ="America/Los_Angeles" date +%Y-%m-%d)" "$bname" "$vid" >> "$UPLOAD_STATE"
    echo "uploaded | $(TZ=\"America/Los_Angeles\" date '+%Y-%m-%d %H:%M %Z') | ${bname} | ${vid}" > "$PROGRESS_FILE"
    return 0
  elif echo "$result" | grep -qi "quota\|quotaExceeded"; then
    echo "  [upload] QUOTA EXCEEDED — stopping uploads for today. Run again tomorrow."
    return 2
  elif echo "$result" | grep -q "invalid_grant"; then
    echo "  [upload] AUTH ERROR: YouTube OAuth token expired/revoked." >&2
    echo "To fix: cd $SCRIPT_DIR && youtubeuploader -secrets client_secrets.json -token request.token" | \
      mail -s "JJ Pipeline: YouTube auth failure — re-auth needed" mail@frank-chen.com
    return 3
  else
    echo "  [upload] FAILED: $result"
    return 1
  fi
}

main() {

STATUS_FILE="$LOG_DIR/${LOG_DATE}-process.status"
PROGRESS_FILE="$LOG_DIR/${LOG_DATE}-process.progress"
PIDFILE="$LOG_DIR/${LOG_DATE}-process.pid"
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

echo "starting | $(TZ=\"America/Los_Angeles\" date '+%Y-%m-%d %H:%M %Z') | pid: $$" > "$STATUS_FILE"

# --- Retry flushing uncopied sstready files to external volume ---
shopt -s nullglob
_uncopied=("$SST_UNCOPIED"/*.mov)
shopt -u nullglob
if [[ ${#_uncopied[@]} -gt 0 ]]; then
  echo "=== Retrying ${#_uncopied[@]} uncopied file(s) to volume ==="
  for _f in "${_uncopied[@]}"; do
    if try_copy_to_volume "$_f"; then
      rm "$_f"
    fi
  done
fi
unset _uncopied _f

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found"; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "ffprobe not found"; exit 1; }
command -v youtubeuploader >/dev/null 2>&1 || { echo "youtubeuploader not found"; exit 1; }

# YouTube credentials
YT_SECRETS="$SCRIPT_DIR/client_secrets.json"
YT_TOKEN="$SCRIPT_DIR/request.token"

[[ -f "$YT_SECRETS" ]] || { echo "Missing $YT_SECRETS"; exit 1; }
[[ -f "$YT_TOKEN" ]] || { echo "Missing $YT_TOKEN"; exit 1; }

# CONFIGURE: Replace with your own YouTube playlist IDs.
# Find these in YouTube Studio → Playlists → click a playlist → copy the list= param from the URL.
PLAYLIST_TEACHING="PLqn-1QlUBKlCBo9J2Pc63uJL-YkgOMzf-"
PLAYLIST_10PSJ="PLqn-1QlUBKlDGWyP6FKdvPui8W74wLB3m"
PLAYLIST_10PSM="PLqn-1QlUBKlCyjUBDOYWXW1Wtw5SI4wNI"

# --- Upload-only mode: upload remaining ytready files, skip conversion ---
if $UPLOAD_ONLY; then
  echo "=== Upload-only mode ==="
  shopt -s nullglob
  ytready_files=("$YTREADY"/*.mov)
  shopt -u nullglob
  if [[ ${#ytready_files[@]} -eq 0 ]]; then
    echo "No .mov files in ytready/. Nothing to upload."
    exit 0
  fi
  echo "Found ${#ytready_files[@]} file(s) in ytready/"
  echo ""
  for f in "${ytready_files[@]}"; do
    bname=$(basename "$f" .mov)
    title="${bname%-ytready}"
    privacy="unlisted"
    playlist=""
    if [[ "$bname" == *"teaching-class-fc"*"-ytready"* ]]; then
      privacy="public"
      playlist="$PLAYLIST_TEACHING"
    elif [[ "$bname" == *"-10psj-"* ]]; then
      playlist="$PLAYLIST_10PSJ"
    elif [[ "$bname" == *"-10psm-"* ]]; then
      playlist="$PLAYLIST_10PSM"
    fi
    upload_exit=0
    yt_upload "$f" "$title" "$privacy" "$playlist" || upload_exit=$?
    if [[ $upload_exit -eq 0 ]]; then
      move_to_trash "$f"
    elif [[ $upload_exit -eq 4 ]]; then
      rm "$f"
      echo "  [cleanup] Stale ytready removed (already uploaded, prior .trash copy kept)"
    elif [[ $upload_exit -eq 2 ]] || [[ $upload_exit -eq 3 ]]; then
      echo ""
      break
    fi
    echo ""
  done
  echo "=== Upload-only done ==="
  exit 0
fi

if $TEACHING_ONLY; then
  process_teaching_folder
  exit 0
fi

# --- Collect all input files from rolling/ with GPS-detected location tags ---
# Format per line: epoch|filepath|location
work_list=""

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  fname=$(basename "$f")
  [[ "$fname" == *"-ytready"* || "$fname" == *"-compressed"* || "$fname" == *"-teaching-class-fc"* || "$fname" == *"-rolling-footage"* ]] && continue
  ep=$(get_epoch "$f")
  [[ -z "$ep" ]] && { echo "WARN: No creation_time for $fname, skipping."; continue; }
  gps_loc=$(get_gps_loc "$f")
  detected_loc="${gps_loc:-10p}"
  if [[ -n "$gps_loc" ]]; then
    echo "  [gps] $fname → $detected_loc (GPS)"
  else
    echo "  [gps] $fname → 10p (no GPS signal)"
  fi
  # Apply --loc filter against GPS-detected location
  [[ -n "$LOC_FILTER" && "$detected_loc" != "$LOC_FILTER" ]] && continue
  work_list="${work_list}${ep}|${f}|${detected_loc}"$'\n'
done < <(find "$SCRIPT_DIR/rolling" -maxdepth 1 -iname "*.mov" 2>/dev/null)

# Remove trailing empty lines
work_list=$(echo "$work_list" | sed '/^$/d')

if [[ -z "$work_list" ]]; then
  echo "No .mov files found to process."
  exit 0
fi

# Sort by epoch (creation time) globally
work_list=$(echo "$work_list" | sort -t'|' -k1,1n)

if [[ $FILE_LIMIT -gt 0 ]]; then
  work_list=$(echo "$work_list" | head -n "$FILE_LIMIT")
  echo "Limiting to $FILE_LIMIT file(s) (oldest first)."
fi

echo "Found $(echo "$work_list" | wc -l | tr -d ' ') file(s) to process."
echo ""

# --- Assign view numbers per session (same date + time_of_day + location) ---
# Build canonical names with view numbers
declare -a FILE_LIST=()
declare -a CANONICAL_LIST=()
declare -a LOCATION_LIST=()
declare -a EPOCH_LIST=()

# Track view counts per session key
prev_session=""
view_counter=0

while IFS='|' read -r ep filepath loc; do
  dow=$(TZ="America/Los_Angeles" date -r "$ep" +%u)
  hour=$(TZ="America/Los_Angeles" date -r "$ep" +%H)
  minute=$(TZ="America/Los_Angeles" date -r "$ep" +%M)
  datestamp=$(TZ="America/Los_Angeles" date -r "$ep" +%Y%m%d)
  day_str=$(day_name "$dow")
  tod_str=$(time_of_day "$hour")

  session_key="${datestamp}-${tod_str}-${loc}"

  if [[ "$session_key" == "$prev_session" ]]; then
    view_counter=$((view_counter + 1))
  else
    view_counter=1
    prev_session="$session_key"
  fi

  if [[ "$loc" == "10p" ]]; then
    canonical="${datestamp}-${day_str}${tod_str}-rolling-footage-view${view_counter}"
  else
    canonical="${datestamp}-${day_str}${tod_str}-${loc}-rolling-footage-view${view_counter}"
  fi

  FILE_LIST+=("$filepath")
  CANONICAL_LIST+=("$canonical")
  LOCATION_LIST+=("$loc")
  EPOCH_LIST+=("$ep")
done <<< "$work_list"

# --- Process each file ---
for i in "${!FILE_LIST[@]}"; do
  echo "processing | $(TZ=\"America/Los_Angeles\" date '+%Y-%m-%d %H:%M %Z') | $(basename "${FILE_LIST[$i]}") | $((i+1))/${#FILE_LIST[@]}" > "$PROGRESS_FILE"
  input_file="${FILE_LIST[$i]}"
  canonical_base="${CANONICAL_LIST[$i]}"
  loc="${LOCATION_LIST[$i]}"
  ep="${EPOCH_LIST[$i]}"
  filename=$(basename "$input_file")

  dow=$(TZ="America/Los_Angeles" date -r "$ep" +%u)
  hour=$(TZ="America/Los_Angeles" date -r "$ep" +%H)
  minute=$(TZ="America/Los_Angeles" date -r "$ep" +%M)
  datestamp=$(TZ="America/Los_Angeles" date -r "$ep" +%Y%m%d)

  echo "=== Processing: $filename ==="
  echo "  [rename] → ${canonical_base} (${loc})"

  # Capture input duration once for verify_output tolerance checks
  input_dur=$(ffprobe -v quiet -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo "")

  # --- Compress with audio → sstready ---
  sst_out="$SSTREADY/${canonical_base}.mov"
  if [[ -f "$sst_out" ]]; then
    echo "  [sstready] Already exists, skipping."
  else
    echo "  [sstready] Compressing with audio..."
    # CONFIGURE: Adjust encoding settings to match your target quality/filesize tradeoff.
    # CRF 23 = good quality; lower = better quality + larger file. scale=WxH sets output resolution.
    ffmpeg -y -loglevel error -hide_banner -nostats -i "$input_file" \
      -c:v libx264 -profile:v high -level 4.1 -preset veryfast -crf 23 \
      -vf "scale=1280:720,fps=30" \
      -b:v 8083k \
      -c:a aac -b:a 191k -ar 44100 \
      -movflags +faststart \
      "$sst_out" || { rm -f "$sst_out"; echo "  [error] ffmpeg failed (sstready) — partial output removed"; exit 1; }
    echo "  [sstready] Done: $(du -h "$sst_out" | cut -f1)"
  fi

  # --- Strip audio from sstready → ytready (stream copy, near-instant) ---
  yt_out="$YTREADY/${canonical_base}-ytready.mov"
  if [[ -f "$yt_out" ]]; then
    echo "  [ytready] Already exists, skipping."
  elif already_uploaded "${canonical_base}-ytready"; then
    echo "  [ytready] Already uploaded — skipping re-creation."
  elif [[ ! -f "$sst_out" ]]; then
    echo "  [ytready] WARN: sstready missing, cannot create ytready."
  else
    echo "  [ytready] Stripping audio from sstready (stream copy)..."
    ffmpeg -y -loglevel error -hide_banner -nostats -i "$sst_out" \
      -c:v copy -an \
      -movflags +faststart \
      "$yt_out" || { rm -f "$yt_out"; echo "  [error] ffmpeg failed (ytready) — partial output removed"; exit 1; }
    echo "  [ytready] Done: $(du -h "$yt_out" | cut -f1)"
  fi

  # --- Teaching video detection ---
  # Rule: create teaching copy only for GPS-detected 10psm videos on Mon/Wed/Fri ~6am.
  # CONFIGURE: Change dow values (0=Sun,1=Mon,...,6=Sat) and total_min range (minutes since midnight UTC)
  # to match your teaching schedule. Current window: 345-390 min = 5:45-6:30 AM PST.
  teaching_sst_out=""
  teaching_yt_out=""
  is_teaching_day=false
  [[ "$dow" == "1" || "$dow" == "3" || "$dow" == "5" ]] && is_teaching_day=true
  total_min=$((10#$hour * 60 + 10#$minute))
  is_teaching_time=false
  [[ $total_min -ge 345 && $total_min -le 390 ]] && is_teaching_time=true

  if [[ "$loc" == "10psm" ]] && $is_teaching_day && $is_teaching_time; then
    teaching_base="${datestamp}-teaching-class-fc-1"
    teaching_sst_out="$SSTREADY/${teaching_base}.mov"
    teaching_yt_out="$YTREADY/${teaching_base}-ytready.mov"

    if [[ -f "$teaching_sst_out" ]]; then
      echo "  [teaching] SST already exists: $(basename "$teaching_sst_out")"
    else
      echo "  [teaching] 10psm Mon/Wed/Fri ~6am → creating SST $(basename "$teaching_sst_out")"
      cp "$sst_out" "$teaching_sst_out"
      log_rename "$sst_out" "$teaching_sst_out"
    fi

    if [[ -f "$teaching_yt_out" ]]; then
      echo "  [teaching] YT already exists: $(basename "$teaching_yt_out")"
    elif already_uploaded "${teaching_base}-ytready"; then
      echo "  [teaching] YT already uploaded — skipping re-creation."
    else
      echo "  [teaching] 10psm Mon/Wed/Fri ~6am → creating YT $(basename "$teaching_yt_out")"
      cp "$yt_out" "$teaching_yt_out"
      log_rename "$yt_out" "$teaching_yt_out"
    fi
  else
    echo "  [teaching] No teaching copy ($(day_name "$dow"), ${hour}:${minute}, loc=${loc})"
  fi

  # --- Post-conversion verification + cleanup ---
  # Source only moves to .trash once ALL applicable outputs are verified non-corrupt
  # and have the correct audio presence (sst=audio, ytready=no audio).
  if already_uploaded "${canonical_base}-ytready" && [[ -f "$sst_out" ]]; then
    echo "  [cleanup] ytready already uploaded — archiving source and sstready directly"
    move_to_trash "$input_file"
    log_rename "$input_file" "$TRASH/$(basename "$input_file")"
    mv "$sst_out" "$SST_UNCOPIED/"
    log_rename "$sst_out" "$SST_UNCOPIED/$(basename "$sst_out")"
    if try_copy_to_volume "$SST_UNCOPIED/$(basename "$sst_out")"; then
      rm "$SST_UNCOPIED/$(basename "$sst_out")"
    fi
    if [[ -n "$teaching_sst_out" && -f "$teaching_sst_out" ]]; then
      mv "$teaching_sst_out" "$SST_UNCOPIED/"
      log_rename "$teaching_sst_out" "$SST_UNCOPIED/$(basename "$teaching_sst_out")"
      if try_copy_to_volume "$SST_UNCOPIED/$(basename "$teaching_sst_out")"; then
        rm "$SST_UNCOPIED/$(basename "$teaching_sst_out")"
      fi
    fi
    echo ""
    continue
  elif [[ -f "$sst_out" && -f "$yt_out" ]]; then
    echo "  [verify] Checking conversion outputs..."
    verify_ok=true

    if ! verify_output "$sst_out" "yes" "$input_dur"; then
      echo "  [verify] FAIL: sstready corrupt or missing audio — $sst_out"
      verify_ok=false
    else
      echo "  [verify] OK: sstready has audio"
    fi

    if ! verify_output "$yt_out" "no" "$input_dur"; then
      echo "  [verify] FAIL: ytready corrupt or unexpectedly has audio — $yt_out"
      verify_ok=false
    else
      echo "  [verify] OK: ytready has no audio"
    fi

    if [[ -n "$teaching_sst_out" && -f "$teaching_sst_out" ]]; then
      if ! verify_output "$teaching_sst_out" "yes" "$input_dur"; then
        echo "  [verify] FAIL: teaching sstready corrupt or missing audio — $teaching_sst_out"
        verify_ok=false
      else
        echo "  [verify] OK: teaching sstready has audio"
      fi
    fi

    if $verify_ok; then
      echo "  [cleanup] All outputs verified — trashing source, archiving sstready"
      move_to_trash "$input_file"
      log_rename "$input_file" "$TRASH/$(basename "$input_file")"
      mv "$sst_out" "$SST_UNCOPIED/"
      log_rename "$sst_out" "$SST_UNCOPIED/$(basename "$sst_out")"
      if try_copy_to_volume "$SST_UNCOPIED/$(basename "$sst_out")"; then
        rm "$SST_UNCOPIED/$(basename "$sst_out")"
      fi
      if [[ -n "$teaching_sst_out" && -f "$teaching_sst_out" ]]; then
        mv "$teaching_sst_out" "$SST_UNCOPIED/"
        log_rename "$teaching_sst_out" "$SST_UNCOPIED/$(basename "$teaching_sst_out")"
        if try_copy_to_volume "$SST_UNCOPIED/$(basename "$teaching_sst_out")"; then
          rm "$SST_UNCOPIED/$(basename "$teaching_sst_out")"
        fi
      fi
    else
      echo "  [cleanup] Verification FAILED — source kept, skipping upload. Investigate outputs before retrying."
      echo ""
      continue
    fi
  else
    echo "  [cleanup] WARNING: conversion output(s) missing — skipping source cleanup and upload"
    echo ""
    continue
  fi

  # --- Skip upload if convert-only mode or quota already exceeded this run ---
  if $CONVERT_ONLY; then
    echo "  [convert-only] Conversions done. Skipping upload — run --upload-only to finish."
    echo ""
    continue
  fi
  if $QUOTA_EXCEEDED; then
    echo "  [upload] Skipping — daily quota reached. Run --upload-only tomorrow."
    echo ""
    continue
  fi

  # --- Upload ytready to YouTube ---
  # Determine playlist and privacy for rolling footage
  rolling_playlist=""
  case "$loc" in
    10psj) rolling_playlist="$PLAYLIST_10PSJ" ;;
    10psm) rolling_playlist="$PLAYLIST_10PSM" ;;
  esac

  upload_exit=0
  yt_upload "$yt_out" "${canonical_base}-ytready" "unlisted" "$rolling_playlist" || upload_exit=$?
  if [[ $upload_exit -eq 2 ]] || [[ $upload_exit -eq 3 ]]; then
    QUOTA_EXCEEDED=true
    echo ""
    continue
  elif [[ $upload_exit -ne 0 ]]; then
    echo "  [skip] Upload failed — ytready kept for retry."
    echo ""
    continue
  fi

  # --- Move uploaded rolling ytready to macOS Trash ---
  echo "  [trash] Moving uploaded ytready to .trash/"
  move_to_trash "$yt_out"
  log_rename "$yt_out" "$TRASH/$(basename "$yt_out")"

  # --- Upload teaching video if created ---
  if [[ -n "$teaching_yt_out" && -f "$teaching_yt_out" ]]; then
    teaching_title=$(basename "$teaching_yt_out" .mov)
    teaching_title="${teaching_title%-ytready}"
    upload_exit=0
    yt_upload "$teaching_yt_out" "$teaching_title" "public" "$PLAYLIST_TEACHING" || upload_exit=$?
    if [[ $upload_exit -eq 2 ]] || [[ $upload_exit -eq 3 ]]; then
      QUOTA_EXCEEDED=true
    elif [[ $upload_exit -eq 0 ]]; then
      echo "  [trash] Moving uploaded teaching ytready to .trash/"
      move_to_trash "$teaching_yt_out"
      log_rename "$teaching_yt_out" "$TRASH/$(basename "$teaching_yt_out")"
    fi
  fi

  echo ""
done

echo "done | $(TZ="America/Los_Angeles" date '+%Y-%m-%d %H:%M %Z') | mode: ${1:-full} | files: ${#FILE_LIST[@]} | uploaded: $(wc -l < "$UPLOAD_STATE" | tr -d ' ')" > "$STATUS_FILE"
rm -f "$PROGRESS_FILE"
echo "=== All done ==="
echo "  Archive (with audio): $SSTREADY/"
echo "  YouTube (no audio):   $YTREADY/"
ls -lh "$SSTREADY/" "$YTREADY/"

}

main 2>&1 | tee -a "$LOG_FILE"
