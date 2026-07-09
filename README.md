# jiujitsu-pipeline

A macOS shell pipeline for automatically ingesting iPhone videos, encoding them for archival and YouTube upload, and routing them to location-based playlists. Designed for a jiu-jitsu instructor filming rolling sessions at multiple gyms — but the structure is generic enough to adapt to any sports or content pipeline.

## How it works

1. **9 PM** — `ingest.sh` moves videos from `~/Downloads` to `rolling/`
2. **3 AM** — `process.sh --convert-only` encodes each video:
   - GPS metadata → auto-detects gym location → assigns location code
   - Produces an archive copy in `sstready/` (H.264, with audio)
   - Produces a delivery copy in `ytready/` (same encode, audio stripped for YouTube)
3. **Manual** — `process.sh --upload-only` uploads `ytready/` files to YouTube, routes each to the matching playlist

## Dependencies

```bash
brew install ffmpeg
brew install porjo/tap/youtubeuploader
```

- `ffmpeg` / `ffprobe` — video encoding and metadata extraction
- `youtubeuploader` — CLI tool for YouTube uploads via OAuth ([GitHub](https://github.com/porjo/youtubeuploader))

## YouTube API setup

This is the most involved step. Do it once.

1. Go to [Google Cloud Console](https://console.cloud.google.com) → create a new project
2. Enable **YouTube Data API v3** under APIs & Services
3. Go to **Credentials** → Create Credentials → OAuth 2.0 Client ID → choose **Desktop app**
4. Download the credentials JSON → rename it `client_secrets.json` → place in the project root
5. Run the uploader once to trigger the OAuth browser flow and save your token:
   ```bash
   youtubeuploader -filename /dev/null -title test 2>&1 | head -5
   # A browser window opens — sign in and authorize
   # This creates request.token in the current directory
   ```
6. Both `client_secrets.json` and `request.token` are gitignored — never commit them

## Folder setup

Create the stage folders (scripts won't auto-create them on first run):

```bash
mkdir -p rolling sstready ytready teaching .trash logs
```

| Folder | Purpose |
|---|---|
| `rolling/` | Drop zone — raw iPhone videos land here |
| `sstready/` | Archive copies (H.264, with audio) |
| `ytready/` | Upload-ready copies (audio stripped) |
| `teaching/` | Optional: manual teaching class footage |
| `.trash/` | Processed source files awaiting deletion |
| `logs/` | Daily logs, rename ledgers, upload state |

## Configuration

**Two places to customize:**

**`pipeline.config`** — stage folder names, phase commands, daily upload quota:
```bash
STAGE_SOURCE="rolling"
STAGE_ARCHIVE="sstready"
STAGE_DELIVER="ytready"
PUBLISH_QUOTA=6
CMD_TRANSFORM="bash process.sh --convert-only"
CMD_PUBLISH="bash process.sh --upload-only"
```

**`process.sh`** — search for `# CONFIGURE:` comments to find:
- GPS coordinates for each gym location
- YouTube playlist IDs (one per location)
- Video encoding settings (resolution, CRF, bitrate)
- Teaching class detection (days of week, time window)

```bash
grep -n "# CONFIGURE:" process.sh
```

## Scheduled automation (macOS)

Install launchd agents to run ingest and conversion automatically:

```bash
bash install-agents.sh
```

This installs two agents:
- `com.frankchen.jiujitsu.ingest` — runs `ingest.sh` at 9 PM daily
- `com.frankchen.jiujitsu.convert` — runs `process.sh --convert-only` at 3 AM daily

To uninstall: `bash install-agents.sh --uninstall`

To test manually: `launchctl start com.frankchen.jiujitsu.ingest`

## Manual workflow

If you're not using launchd, run the phases yourself:

```bash
bash ingest.sh                          # move ~/Downloads videos → rolling/
bash process.sh --convert-only         # encode rolling/ → sstready/ + ytready/
bash process.sh --upload-only          # upload ytready/ to YouTube
```

Other flags:
```bash
bash process.sh --loc 10psj            # process only San Jose location
bash process.sh --limit 3              # process only 3 oldest files
bash process.sh --teaching-only        # process only teaching/ folder
YT_DAILY_LIMIT=10 bash process.sh --upload-only  # override daily quota
```

## Claude Code skills

If you use [Claude Code](https://claude.ai/code), a `/video-pipeline` skill is included:

```
/video-pipeline status              # what's in each stage, what's next
/video-pipeline transform           # encode rolling/ → sstready/ + ytready/
/video-pipeline publish             # upload ytready/ to YouTube
/video-pipeline trace IMG_1234      # find where a specific file is in the pipeline
```

## Logs

All logs are written to `logs/` with a daily `YYYY-MM-DD-` prefix:

| File | Contents |
|---|---|
| `*-process.md` | Full structured log of each conversion run |
| `*-process.status` | Current pipeline state: starting / running / done / failed |
| `*-renames.tsv` | Original filename → canonical filename ledger |
| `*-upload-state.tsv` | Filename → YouTube video ID for every upload |
| `*-ingest.log` | Files moved from Downloads to rolling/ |
