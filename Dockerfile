# Jellyfin for Railway.
#
# Upstream's image keeps every durable file under /config and /cache, which are
# declared VOLUMEs. A Railway template mounts exactly one volume, so this wrapper
# relocates the whole program-data tree onto /data and patches the listen port,
# which Jellyfin reads from network.xml rather than from $PORT.
FROM jellyfin/jellyfin:10.11.11

# python3 is used for the offline password rotation (PBKDF2-SHA512 + sqlite).
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

# Everything Jellyfin persists now lives under the single Railway volume.
ENV JELLYFIN_DATA_DIR=/data \
    JELLYFIN_CONFIG_DIR=/data/config \
    JELLYFIN_CACHE_DIR=/data/cache \
    JELLYFIN_LOG_DIR=/data/log \
    XDG_CACHE_HOME=/data/cache \
    JELLYFIN_ADMIN_USERNAME=admin

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY seed.py /usr/local/lib/jellyfin-railway-seed.py
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

EXPOSE 8096
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
