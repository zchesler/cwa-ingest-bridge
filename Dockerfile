FROM alpine:3.20

LABEL org.opencontainers.image.title="cwa-ingest-bridge"
LABEL org.opencontainers.image.description="Copies every ebook Chaptarr imports into a Calibre-Web-Automated ingest folder."
LABEL org.opencontainers.image.licenses="MIT"

# tzdata lets TZ=Region/City take effect; without it log timestamps stay UTC.
RUN apk add --no-cache bash curl jq tzdata

COPY bridge.sh /usr/local/bin/bridge.sh
RUN chmod +x /usr/local/bin/bridge.sh

ENV LIBRARY=/library \
    CWA_INGEST=/ingest \
    STATE_DIR=/state

# Runs as the owner of CWA's ingest folder (nobody:users on Unraid), so copies
# land with the right owner. Override with `user:` in compose if yours differs.
USER 99:100

# The heartbeat is touched after every successful read of Chaptarr's history.
HEALTHCHECK --interval=60s --timeout=10s --start-period=2m \
  CMD find /state/heartbeat -mmin -10 2>/dev/null | grep -q . || exit 1

ENTRYPOINT ["/usr/local/bin/bridge.sh"]
