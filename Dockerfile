# syntax=docker/dockerfile:1
#
# ghcr.io/reclyptor/factorio — Factorio headless server on the GameOps toolkit.
# Adapter contract: https://github.com/Reclyptor/GameOps/blob/master/docs/CONTRACT.md

ARG GAMEOPS_VERSION=1.1.1
FROM ghcr.io/reclyptor/gameops:${GAMEOPS_VERSION} AS gameops

FROM debian:trixie-slim

# Version and checksum of the headless tarball baked into the image. Runtime
# updates replace it; this is the starting point, not a pin on what runs.
ARG RELEASE_VERSION=2.0.77
ARG RELEASE_SHA256=c4efc11529f74d37c96933e291e0db73fd9f5aa4738913d9301b24680b3e947f
ARG PUID=845
ARG PGID=845

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# xz-utils: the headless tarball is .tar.xz (also needed for runtime updates).
# curl is build-time only.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates xz-utils curl \
 && groupadd --system --gid "${PGID}" factorio \
 && useradd --system --uid "${PUID}" --gid "${PGID}" --no-create-home --shell /usr/sbin/nologin factorio \
 && curl -fsSL --retry 5 -o /tmp/factorio.tar.xz \
        "https://www.factorio.com/get-download/${RELEASE_VERSION}/headless/linux64" \
 && echo "${RELEASE_SHA256}  /tmp/factorio.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/factorio \
 && tar -xJf /tmp/factorio.tar.xz --strip-components=1 -C /opt/factorio \
 && rm /tmp/factorio.tar.xz \
 && apt-get purge -y --auto-remove curl \
 && rm -rf /var/lib/apt/lists/* \
 && install -d -o "${PUID}" -g "${PGID}" /data /backups \
 && chown -R "${PUID}:${PGID}" /opt/factorio

COPY --from=gameops /opt/gameops /opt/gameops
COPY adapter/ /opt/game/

# config.ini is what makes the game write to /data; the adapter rewrites it
# after every update because the tarball ships its own.
RUN chmod 0644 /opt/game/adapter.sh /opt/game/lib/*.sh /opt/game/templates/* \
 && bash -n /opt/game/adapter.sh /opt/game/lib/*.sh \
 && /opt/gameops/bin/gameops json get /opt/game/templates/server-settings.json .name >/dev/null \
 && bash -c 'source /opt/game/lib/install.sh && factorio_write_config_ini /opt/factorio /data' \
 && /opt/factorio/bin/x64/factorio --version | head -1

ENV PATH="/opt/gameops/bin:${PATH}" \
    DATA_DIR=/data \
    BACKUP_DIR=/backups \
    SERVER_NAME="Factorio" \
    PORT=34197 \
    RCON_PORT=27015 \
    CHANNEL=stable \
    WORLD_NAME=world \
    LOAD_LATEST_SAVE=true \
    DLC_SPACE_AGE=true

USER ${PUID}:${PGID}
VOLUME ["/data", "/backups"]
EXPOSE 34197/udp 27015/tcp 9110/tcp
HEALTHCHECK --interval=60s --timeout=10s --start-period=15m --retries=3 CMD ["gameops", "health"]
ENTRYPOINT ["gameops", "run"]

LABEL org.opencontainers.image.title="factorio" \
      org.opencontainers.image.description="Factorio headless server with backups, in-place auto-updates, Discord notifications and player events, on the GameOps toolkit" \
      org.opencontainers.image.source="https://github.com/Reclyptor/Factorio" \
      org.opencontainers.image.licenses="MIT" \
      factorio.version="${RELEASE_VERSION}"
