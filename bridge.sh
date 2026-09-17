#!/usr/bin/env bash
# cwa-ingest-bridge — copies every ebook Chaptarr imports into
# Calibre-Web-Automated's ingest folder.
#
# The trigger is Chaptarr's own history: each "bookFileImported" event names
# the file it just put in the library. Unlike watching the library folder,
# that only sees real imports (not renames, retags or library scans), works
# when the library lives on another machine, and catches up on anything
# imported while the bridge was down.
set -uo pipefail

: "${CHAPTARR_URL:?CHAPTARR_URL must be set, e.g. http://192.168.1.10:8789}"
: "${CHAPTARR_API_KEY:?CHAPTARR_API_KEY must be set}"
CHAPTARR_URL="${CHAPTARR_URL%/}"
# Chaptarr's ebook root folder as Chaptarr sees it, and the same folder as
# mounted in this container.
CHAPTARR_EBOOK_ROOT="${CHAPTARR_EBOOK_ROOT:-/ebooks}"
CHAPTARR_EBOOK_ROOT="${CHAPTARR_EBOOK_ROOT%/}"
LIBRARY="${LIBRARY:-/library}"
CWA_INGEST="${CWA_INGEST:-/ingest}"
STATE_DIR="${STATE_DIR:-/state}"
EXTENSIONS="${EXTENSIONS:-epub,kepub,azw3,azw,mobi,pdf,fb2}"
POLL_SECONDS="${POLL_SECONDS:-60}"
# A book that can't be copied is retried on every poll, this many times.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
PAGE_SIZE="${PAGE_SIZE:-100}"
# Optional: ntfy topic URL (and token) to hear about books that couldn't be copied.
NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"

LAST_ID_FILE="$STATE_DIR/last-history-id"
PENDING_FILE="$STATE_DIR/pending" # history id <TAB> attempts <TAB> path in Chaptarr
HEARTBEAT_FILE="$STATE_DIR/heartbeat"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

notify() { # title, message
  [ -n "$NTFY_URL" ] || return 0
  local auth=()
  [ -n "$NTFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS -m 15 "${auth[@]}" -H "Title: $1" -H "Tags: books,warning" --data-binary "$2" "$NTFY_URL" >/dev/null ||
    log "WARN: couldn't send the ntfy notification"
}

api_get() { # path and query under /api/v1/
  curl -fsS -m 30 -H "X-Api-Key: $CHAPTARR_API_KEY" "$CHAPTARR_URL/api/v1/$1"
}

IFS=',' read -ra WANTED <<<"$(printf '%s' "$EXTENSIONS" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

is_ebook() {
  local name="${1##*/}"
  local ext="${name##*.}"
  [ "$ext" != "$name" ] || return 1
  ext="${ext,,}"
  local wanted
  for wanted in "${WANTED[@]}"; do
    [ "$ext" = "$wanted" ] && return 0
  done
  return 1
}

# Sets COPIED_TO on success, REASON on failure.
copy_to_ingest() { # history id, path in Chaptarr
  local src="$LIBRARY/${2#"$CHAPTARR_EBOOK_ROOT"/}"
  if [ ! -f "$src" ]; then
    REASON="not found at $src"
    return 1
  fi
  local name="${src##*/}"
  local dest="$CWA_INGEST/$name"
  # A book with the same file name that CWA hasn't taken yet.
  [ -e "$dest" ] && dest="$CWA_INGEST/${name%.*} (chaptarr $1).${name##*.}"
  local err
  # CWA ignores .part files, so it never picks up a half-copied book.
  if ! err="$(cp -- "$src" "$dest.part" 2>&1 && mv -f -- "$dest.part" "$dest" 2>&1)"; then
    rm -f -- "$dest.part"
    REASON="${err:-copy failed}"
    return 1
  fi
  COPIED_TO="$dest"
}

# Adds new ebook imports from Chaptarr's history to the pending list.
collect_imports() {
  local last newest body page=1 imports=""
  last="$(cat "$LAST_ID_FILE")"
  newest="$last"
  while :; do
    body="$(api_get "history?page=$page&pageSize=$PAGE_SIZE&sortKey=date&sortDirection=descending")" || return 1
    imports+="$(jq -r --argjson last "$last" '
      .records[]
      | select(.id > $last and .eventType == "bookFileImported" and ((.data.importedPath // "") != ""))
      | [.id, .data.importedPath] | @tsv' <<<"$body")"$'\n' || return 1
    newest="$(jq -r --argjson n "$newest" '[$n, (.records[].id)] | max' <<<"$body")" || return 1
    # Newest first: stop at events already seen, or at the last page.
    jq -e --argjson last "$last" --argjson size "$PAGE_SIZE" \
      '(.records | length) < $size or any(.records[]; .id <= $last)' <<<"$body" >/dev/null && break
    page=$((page + 1))
    [ "$page" -le 50 ] || break
  done

  local id path
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] || continue
    case "$path" in "$CHAPTARR_EBOOK_ROOT"/*) ;; *) continue ;; esac
    is_ebook "$path" || continue
    grep -q "^$id"$'\t' "$PENDING_FILE" || printf '%s\t0\t%s\n' "$id" "$path" >>"$PENDING_FILE"
  done < <(sort -n <<<"$imports")
  printf '%s\n' "$newest" >"$LAST_ID_FILE"
}

copy_pending() {
  local id attempts path kept="$PENDING_FILE.new"
  : >"$kept"
  while IFS=$'\t' read -r -u 3 id attempts path; do
    [ -n "$id" ] || continue
    if copy_to_ingest "$id" "$path"; then
      log "copied: $path -> $COPIED_TO"
      continue
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
      log "ERROR: giving up on $path after $attempts attempts: $REASON"
      notify "Book not added to Calibre" "Couldn't copy $path into the CWA ingest folder after $attempts attempts: $REASON"
    else
      log "WARN: couldn't copy $path (attempt $attempts of $MAX_ATTEMPTS): $REASON"
      printf '%s\t%s\t%s\n' "$id" "$attempts" "$path" >>"$kept"
    fi
  done 3<"$PENDING_FILE"
  mv -f "$kept" "$PENDING_FILE"
}

mkdir -p "$STATE_DIR"
touch "$PENDING_FILE"

log "cwa-ingest-bridge starting: Chaptarr imports under $CHAPTARR_EBOOK_ROOT ($EXTENSIONS) -> $LIBRARY -> $CWA_INGEST, every ${POLL_SECONDS}s"

if [ ! -s "$LAST_ID_FILE" ]; then
  if [ -n "${START_AFTER_ID:-}" ]; then
    printf '%s\n' "$START_AFTER_ID" >"$LAST_ID_FILE"
    log "first run: copying imports after history id $START_AFTER_ID"
  else
    newest="$(api_get "history?page=1&pageSize=1&sortKey=date&sortDirection=descending" | jq -r '[0, (.records[].id)] | max')" || {
      log "ERROR: couldn't read Chaptarr's history at $CHAPTARR_URL"
      exit 1
    }
    printf '%s\n' "$newest" >"$LAST_ID_FILE"
    log "first run: starting after history id $newest (set START_AFTER_ID to also copy earlier imports)"
  fi
fi

[ -w "$CWA_INGEST" ] || log "WARN: $CWA_INGEST isn't writable by uid $(id -u); copies will fail until it is"

failures=0
while :; do
  if collect_imports; then
    [ "$failures" -ge "$MAX_ATTEMPTS" ] && log "Chaptarr's history is readable again"
    failures=0
    touch "$HEARTBEAT_FILE"
  else
    failures=$((failures + 1))
    log "WARN: couldn't read Chaptarr's history ($failures in a row)"
    [ "$failures" -eq "$MAX_ATTEMPTS" ] &&
      notify "Calibre bridge can't reach Chaptarr" "cwa-ingest-bridge couldn't read Chaptarr's history at $CHAPTARR_URL for $failures polls in a row, so new ebooks aren't reaching Calibre."
  fi
  copy_pending
  [ -n "${ONCE:-}" ] && break
  sleep "$POLL_SECONDS"
done
