FROM alpine:3.20

LABEL org.opencontainers.image.title="cwa-ingest-bridge"
LABEL org.opencontainers.image.description="Watches a folder for new ebook files and copies them into a Calibre-Web-Automated ingest folder."
LABEL org.opencontainers.image.licenses="MIT"

# tzdata lets TZ=Region/City take effect; without it log timestamps stay UTC.
RUN apk add --no-cache bash inotify-tools tzdata

COPY watch.sh /usr/local/bin/watch.sh
RUN chmod +x /usr/local/bin/watch.sh

# Runs as root so it can chown copied files to PUID:PGID at runtime.
ENV WATCH_FOLDER=/watch \
    CWA_INGEST=/ingest \
    WATCH_EXTENSIONS=epub,mobi,azw3,pdf \
    PUID=99 \
    PGID=100

VOLUME ["/watch", "/ingest"]

ENTRYPOINT ["/usr/local/bin/watch.sh"]
