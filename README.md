# cwa-ingest-bridge

Lightweight bridge container for a Chaptarr -> Calibre-Web-Automated pipeline
on Unraid. Watches a folder recursively and **copies** (never moves) any new
ebook file into CWA's ingest folder as soon as the download finishes.

It does nothing else: no library management, no metadata, no moving/deleting
source files. Chaptarr keeps its own copy; CWA picks up the copy and imports
it on its own schedule.

## How it works

`watch.sh` runs `inotifywait -m -r` against `$WATCH_FOLDER`, listening for
`close_write` (file finished writing) and `moved_to` (file moved/renamed into
the tree, e.g. out of a client's `.tmp`/`.part` staging name) events. For each
event it checks the file extension against `$WATCH_EXTENSIONS` (case
insensitive) and, if it matches, copies the file into `$CWA_INGEST` and
`chown`s the copy to `$PUID:$PGID`. Everything else in the watched folder is
ignored, including partial/temp files from the download client.

Every detected file and every copy is logged to stdout with a timestamp.

## Environment variables

| Variable           | Default               | Description                                      |
|---------------------|------------------------|---------------------------------------------------|
| `WATCH_FOLDER`       | `/watch`               | Folder to watch recursively for new ebook files.   |
| `CWA_INGEST`         | `/ingest`               | Folder to copy matching files into.                |
| `WATCH_EXTENSIONS`   | `epub,mobi,azw3,pdf`   | Comma-separated, case-insensitive extension list.  |
| `PUID`               | `99`                   | UID to chown copied files to.                      |
| `PGID`               | `100`                  | GID to chown copied files to.                      |

`WATCH_FOLDER` and `CWA_INGEST` inside the container are fixed by the image
defaults above; map your real host paths onto `/watch` and `/ingest` with
bind mounts (see `docker-compose.yml`).

## Usage (Dockge / Unraid)

Paste [`docker-compose.yml`](docker-compose.yml) into Dockge as a new stack,
then replace the two bind mount paths with your actual host paths:

```yaml
volumes:
  - /mnt/user/data/chaptarr/complete:/watch
  - /mnt/user/appdata/calibre-web-automated/ingest:/ingest
```

The image is published to `ghcr.io/zchesler/cwa-ingest-bridge` on every push
to `main` via GitHub Actions (see `.github/workflows/publish.yml`).

## Local build

```bash
docker build -t cwa-ingest-bridge .
docker run --rm \
  -e PUID=99 -e PGID=100 \
  -v /path/to/watch:/watch \
  -v /path/to/ingest:/ingest \
  cwa-ingest-bridge
```
