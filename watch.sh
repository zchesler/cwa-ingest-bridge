#!/usr/bin/env bash
# cwa-ingest-bridge — watches WATCH_FOLDER and copies new ebook files into
# CWA_INGEST for a Chaptarr -> Calibre-Web-Automated pipeline.
set -euo pipefail

: "${WATCH_FOLDER:?WATCH_FOLDER must be set}"
: "${CWA_INGEST:?CWA_INGEST must be set}"
WATCH_EXTENSIONS="${WATCH_EXTENSIONS:-epub,mobi,azw3,pdf}"
PUID="${PUID:-99}"
PGID="${PGID:-100}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

IFS=',' read -ra EXT_ARR <<< "$WATCH_EXTENSIONS"

is_wanted_extension() {
  local filename="$1"
  local ext="${filename##*.}"
  [ "$ext" = "$filename" ] && return 1   # no extension at all
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  local candidate
  for candidate in "${EXT_ARR[@]}"; do
    candidate="$(printf '%s' "$candidate" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ "$ext" = "$candidate" ] && return 0
  done
  return 1
}

mkdir -p "$CWA_INGEST"

log "cwa-ingest-bridge starting: watching '$WATCH_FOLDER' -> '$CWA_INGEST' (extensions: $WATCH_EXTENSIONS, owner: $PUID:$PGID)"

inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$WATCH_FOLDER" |
while IFS= read -r filepath; do
  filename="$(basename "$filepath")"

  # A move within the watched tree can fire moved_to for a directory, and a
  # file can vanish between the event and this read (temp/partial files).
  [ -f "$filepath" ] || continue

  if ! is_wanted_extension "$filename"; then
    continue
  fi

  log "detected: $filepath"

  dest="$CWA_INGEST/$filename"
  if cp "$filepath" "$dest"; then
    chown "$PUID:$PGID" "$dest"
    log "copied: $filepath -> $dest"
  else
    log "ERROR: failed to copy $filepath"
  fi
done
