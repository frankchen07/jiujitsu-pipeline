# run

Operate a staged media processing pipeline. Works with any project that has a `pipeline.config` file in the project root.

## Setup

Before doing anything, source `pipeline.config` to learn the project's stage folders and commands. All folder paths are relative to the project root.

## Invocation modes

### `/run status`
Report the current state of all pipeline stages and what action is next.

Steps:
1. Source `pipeline.config`
2. Count files in each stage folder: `$STAGE_SOURCE`, `$STAGE_ARCHIVE`, `$STAGE_DELIVER`, `$STAGE_TRASH`
3. Read today's status log: `$LOG_DIR/$(date +$LOG_DATE_FORMAT)-process.status` — if it exists, show its value (starting/running/done/failed)
4. Read today's upload state log: `$LOG_DIR/$(date +$LOG_DATE_FORMAT)-upload-state.tsv` — count lines to get today's publish count
5. Read today's progress file: `$LOG_DIR/$(date +$LOG_DATE_FORMAT)-process.progress` — if it exists, show what's currently processing
6. Output a one-liner: `"N raw → N transforming → N queued for publish (N/$PUBLISH_QUOTA today)"`
7. Suggest the next logical action based on what's pending

### `/run ingest`
Move source files from the drop zone (e.g. ~/Downloads) into `$STAGE_SOURCE`.

Steps:
1. Source `pipeline.config`
2. Show the user: `Will run: $CMD_INGEST`
3. Run it and stream output

### `/run transform`
Encode source files from `$STAGE_SOURCE` into `$STAGE_ARCHIVE` and `$STAGE_DELIVER`.

Steps:
1. Source `pipeline.config`
2. Count files in `$STAGE_SOURCE` — if 0, say "Nothing in source stage, nothing to transform"
3. Show the user: `Will run: $CMD_TRANSFORM`
4. Run it and stream output. Tail `$LOG_DIR/$(date +$LOG_DATE_FORMAT)-process.md` for structured output.

### `/run publish`
Upload files from `$STAGE_DELIVER` to the target platform.

Steps:
1. Source `pipeline.config`
2. Count files in `$STAGE_DELIVER` — if 0, say "Nothing queued for publish"
3. Check today's publish count vs `$PUBLISH_QUOTA` — if at quota, say "Daily quota reached ($PUBLISH_QUOTA/$PUBLISH_QUOTA)"
4. **Confirm with user before executing**: show `Will run: $CMD_PUBLISH` and ask for approval
5. On approval, run and stream output

### `/run full`
Run the complete pipeline in one pass (transform + publish).

Steps:
1. Source `pipeline.config`
2. Show the user: `Will run: $CMD_FULL`
3. **Confirm before executing** — this will both transform and publish
4. On approval, run and stream output

### `/run trace [filename]`
Find where a file is in the pipeline lifecycle.

Steps:
1. Source `pipeline.config`
2. Search each stage folder for a file matching the given name (partial match ok): `$STAGE_SOURCE`, `$STAGE_ARCHIVE`, `$STAGE_DELIVER`, `$STAGE_TRASH`
3. Grep `$LOG_DIR/*-renames.tsv` for any rename record (original → canonical name mapping)
4. Grep `$LOG_DIR/*-upload-state.tsv` for any publish record (file → platform ID)
5. If file is found and accessible, run `ffprobe` to show duration, codec, and any embedded metadata
6. Report: current location, rename history, publish status, next expected action

## Error handling

- If `pipeline.config` is missing: tell the user the file is required and show the expected format
- If a command fails mid-run: surface the exit code and tail the most recent log file for context
- Never retry a failed publish automatically — duplicate uploads are hard to undo
