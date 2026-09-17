# cwa-ingest-bridge

Lightweight bridge container for a Chaptarr -> Calibre-Web-Automated pipeline
on Unraid. Every ebook Chaptarr imports is **copied** (never moved) into CWA's
ingest folder, and CWA adds it to the Calibre library on its own.

It does nothing else: no library management, no metadata, no moving/deleting
source files. Chaptarr keeps its own copy.

## How it works

Every minute, `bridge.sh` reads Chaptarr's history (`/api/v1/history`) and
picks up new `bookFileImported` events for files under Chaptarr's ebook root
folder with an ebook extension. For each one it finds the same file through
its own mount of the library and copies it into `$CWA_INGEST` — first as
`name.epub.part`, which CWA ignores, then renamed, so CWA never sees a
half-copied book.

- **Only real imports.** Renames, retags and library rescans aren't imports,
  so they don't send a book to Calibre again. Upgrades are imports and do.
- **Nothing is missed.** The last history id it handled is kept in `/state`,
  so imports that happened while the container was stopped are copied when
  it starts again. A book that can't be copied (not readable yet, ingest
  folder not writable) is retried on every poll, `MAX_ATTEMPTS` times, and
  then reported over ntfy if `NTFY_URL` is set.
- **Runs next to CWA.** It writes into the ingest folder locally, as the
  folder's owner. Writing over SMB from another machine breaks whenever CWA
  restarts: CWA's init runs `install -d` on the ingest folder, which resets it
  to `755`, so only its owner can create files there.

On its very first start it begins after the newest history event, so old
imports aren't copied. Set `START_AFTER_ID` to a history id to include
imports after it.

Every copy, retry and failure is logged to stdout with a timestamp. The
container is healthy while it can read Chaptarr's history.

## Environment variables

| Variable              | Default                             | Description                                                         |
|-----------------------|-------------------------------------|---------------------------------------------------------------------|
| `CHAPTARR_URL`        | —                                   | Chaptarr's address, e.g. `http://192.168.1.10:8789`.                |
| `CHAPTARR_API_KEY`    | —                                   | Chaptarr → Settings → General → API Key.                            |
| `CHAPTARR_EBOOK_ROOT` | `/ebooks`                           | Chaptarr's ebook root folder, as Chaptarr sees it.                  |
| `LIBRARY`             | `/library`                          | The same folder, as mounted in this container.                      |
| `CWA_INGEST`          | `/ingest`                           | CWA's ingest folder, as mounted in this container.                  |
| `EXTENSIONS`          | `epub,kepub,azw3,azw,mobi,pdf,fb2`  | Comma-separated, case-insensitive.                                  |
| `POLL_SECONDS`        | `60`                                | How often to read Chaptarr's history.                               |
| `MAX_ATTEMPTS`        | `30`                                | Polls to keep retrying a book before giving up and notifying.       |
| `NTFY_URL`            | —                                   | Optional ntfy topic URL for failures, e.g. `https://ntfy.sh/books`. |
| `NTFY_TOKEN`          | —                                   | Optional ntfy access token.                                         |
| `START_AFTER_ID`      | —                                   | First start only: copy imports after this history id.               |
| `TZ`                  | `UTC`                               | Timezone for log timestamps, e.g. `Asia/Jerusalem`.                 |

The image runs as `99:100` (nobody:users, the usual owner on Unraid). Use
`user:` in compose if your ingest folder belongs to someone else.

## Usage (Dockge / Unraid)

Paste [`docker-compose.yml`](docker-compose.yml) into Dockge as a new stack on
the machine running CWA, set the paths and `CHAPTARR_URL`, and put
`CHAPTARR_API_KEY` (and `NTFY_URL` / `NTFY_TOKEN`) in the stack's `.env`.

The image is published to `ghcr.io/zchesler/cwa-ingest-bridge` on every push
to `main` via GitHub Actions (see `.github/workflows/publish.yml`), after
`test/run.sh` passes.

## Tests

```bash
test/run.sh   # needs bash, curl, jq and python3
```

Runs `bridge.sh` against a fake Chaptarr history API and checks what ends up
in the ingest folder.
