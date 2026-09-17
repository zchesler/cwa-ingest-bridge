#!/usr/bin/env bash
# End-to-end check of bridge.sh against a fake Chaptarr history API.
# Needs bash, curl, jq and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
server=""
cleanup() {
  [ -n "$server" ] && kill "$server" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$work/api/api/v1" "$work/library/Lisa See/Daughters" "$work/ingest" "$work/state"
echo "epub" >"$work/library/Lisa See/Daughters/Daughters.epub"
cat >"$work/api/api/v1/history" <<'JSON'
{"page": 1, "pageSize": 100, "totalRecords": 5, "records": [
  {"id": 14, "eventType": "bookFileImported", "data": {"importedPath": "/ebooks/Later/Later.epub"}},
  {"id": 13, "eventType": "bookFileImported", "data": {"importedPath": "/audiobooks/Someone/Book.m4b"}},
  {"id": 12, "eventType": "grabbed", "data": {}},
  {"id": 11, "eventType": "bookFileImported", "data": {"importedPath": "/ebooks/Lisa See/Daughters/Daughters.epub"}},
  {"id": 10, "eventType": "bookFileImported", "data": {"importedPath": "/ebooks/Old/Already.epub"}}
]}
JSON

port=18789
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/api" >/dev/null 2>&1 &
server=$!
for _ in $(seq 50); do
  curl -fs "http://127.0.0.1:$port/api/v1/history" >/dev/null && break
  sleep 0.1
done

run() {
  env CHAPTARR_URL="http://127.0.0.1:$port" CHAPTARR_API_KEY=test \
    LIBRARY="$work/library" CWA_INGEST="$work/ingest" STATE_DIR="$work/state" \
    MAX_ATTEMPTS=2 ONCE=1 "$@" bash bridge.sh
}

# Imports after id 10: the ebook is copied, the audiobook and other events
# are ignored, and the ebook that isn't in the library yet waits.
run START_AFTER_ID=10
[ -f "$work/ingest/Daughters.epub" ] || fail "the new ebook wasn't copied"
[ "$(ls "$work/ingest")" = "Daughters.epub" ] || fail "unexpected files in ingest: $(ls "$work/ingest")"
[ "$(cat "$work/state/last-history-id")" = 14 ] || fail "last history id wasn't advanced"
grep -q $'^14\t1\t/ebooks/Later/Later.epub$' "$work/state/pending" || fail "the missing ebook isn't pending"

# CWA took the first book; the missing one shows up and is copied on the next
# poll, and nothing is copied twice.
rm "$work/ingest/Daughters.epub"
mkdir -p "$work/library/Later" && echo "epub" >"$work/library/Later/Later.epub"
run
[ "$(ls "$work/ingest")" = "Later.epub" ] || fail "expected only Later.epub, got: $(ls "$work/ingest")"
[ ! -s "$work/state/pending" ] || fail "pending should be empty"

# A same-named book CWA hasn't taken yet isn't overwritten.
echo "new copy" >"$work/library/Later/Later.epub"
printf '14\t0\t/ebooks/Later/Later.epub\n' >"$work/state/pending"
run
[ -f "$work/ingest/Later (chaptarr 14).epub" ] || fail "a same-named file was overwritten"

# Gives up after MAX_ATTEMPTS.
printf '99\t0\t/ebooks/Gone/Gone.epub\n' >"$work/state/pending"
run && run
[ ! -s "$work/state/pending" ] || fail "should give up after MAX_ATTEMPTS"

# First run without START_AFTER_ID starts after the newest event.
rm -rf "$work/state" "$work/ingest" && mkdir -p "$work/state" "$work/ingest"
run
[ "$(cat "$work/state/last-history-id")" = 14 ] || fail "first run should start after the newest event"
[ -z "$(ls "$work/ingest")" ] || fail "first run shouldn't copy old imports"

echo "all bridge tests passed"
