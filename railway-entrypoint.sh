#!/usr/bin/env bash
# Railway entrypoint for Jellyfin.
#
# Three jobs, in order:
#   1. Refuse to boot without an admin credential, and complete Jellyfin's
#      setup wizard before the public port is ever bound. The wizard is
#      unauthenticated by design, so on a public URL the first stranger to
#      reach it becomes the administrator.
#   2. Put the listen port where Railway's proxy and healthcheck expect it.
#      Jellyfin ignores $PORT; the value lives in network.xml.
#   3. Size the transcoder's thread pool from the container's CPU quota
#      instead of the host's core count.
set -euo pipefail

DATA_ROOT="${JELLYFIN_DATA_DIR:-/data}"
CONFIG_DIR="${JELLYFIN_CONFIG_DIR:-$DATA_ROOT/config}"
DB_PATH="$DATA_ROOT/data/jellyfin.db"
SEEDED_MARKER="$DATA_ROOT/.railway-seeded"
SEED_PORT=18096
PORT="${PORT:-8096}"

log() { echo "[railway-entrypoint] $*"; }

if [ -z "${JELLYFIN_ADMIN_PASSWORD:-}" ]; then
  echo "[railway-entrypoint] FATAL: JELLYFIN_ADMIN_PASSWORD is empty." >&2
  echo "[railway-entrypoint] Jellyfin's setup wizard authenticates nobody, so a" >&2
  echo "[railway-entrypoint] deploy without a seeded administrator is claimable" >&2
  echo "[railway-entrypoint] by anyone who opens the URL. Refusing to start." >&2
  exit 1
fi
ADMIN_USER="${JELLYFIN_ADMIN_USERNAME:-admin}"

mkdir -p "$DATA_ROOT"/{config,data,cache,log,metadata,transcodes,root}

write_network_xml() {
  local listen_port="$1" published=""
  if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    published="  <PublishedServerUriBySubnet>
    <string>all=https://${RAILWAY_PUBLIC_DOMAIN}</string>
  </PublishedServerUriBySubnet>"
  else
    published="  <PublishedServerUriBySubnet />"
  fi
  cat > "$CONFIG_DIR/network.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <BaseUrl />
  <EnableHttps>false</EnableHttps>
  <RequireHttps>false</RequireHttps>
  <CertificatePath />
  <CertificatePassword />
  <InternalHttpPort>${listen_port}</InternalHttpPort>
  <InternalHttpsPort>8920</InternalHttpsPort>
  <PublicHttpPort>443</PublicHttpPort>
  <PublicHttpsPort>443</PublicHttpsPort>
  <AutoDiscovery>false</AutoDiscovery>
  <EnableIPv4>true</EnableIPv4>
  <EnableIPv6>false</EnableIPv6>
  <EnableRemoteAccess>true</EnableRemoteAccess>
  <LocalNetworkSubnets />
  <LocalNetworkAddresses />
  <KnownProxies />
  <IgnoreVirtualInterfaces>true</IgnoreVirtualInterfaces>
  <VirtualInterfaceNames>
    <string>veth</string>
  </VirtualInterfaceNames>
  <EnablePublishedServerUriByRequest>false</EnablePublishedServerUriByRequest>
${published}
  <RemoteIPFilter />
  <IsRemoteIPFilterBlacklist>false</IsRemoteIPFilterBlacklist>
</NetworkConfiguration>
XML
}

# /health answers 200 while the server is still applying database migrations,
# and every wizard route returns 503 until that finishes -- so readiness is the
# wizard route itself, not the health endpoint.
wait_for_wizard() {
  local base="$1" i
  for i in $(seq 1 150); do
    if curl -fsS -o /dev/null "$base/Startup/User"; then return 0; fi
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------- seed
# The wizard runs against a loopback-only port that Railway does not route,
# so the instance is never reachable in its claimable state.
if [ ! -f "$SEEDED_MARKER" ]; then
  log "first boot: completing the setup wizard before the public port opens"
  write_network_xml "$SEED_PORT"
  /jellyfin/jellyfin &
  seed_pid=$!
  base="http://127.0.0.1:$SEED_PORT"
  if ! wait_for_wizard "$base"; then
    log "FATAL: Jellyfin did not become ready during seeding"
    kill "$seed_pid" 2>/dev/null || true
    exit 1
  fi
  curl -fsS -o /dev/null -X POST "$base/Startup/Configuration" \
    -H 'Content-Type: application/json' \
    -d "{\"UICulture\":\"${JELLYFIN_UI_CULTURE:-en-US}\",\"MetadataCountryCode\":\"${JELLYFIN_METADATA_COUNTRY:-US}\",\"PreferredMetadataLanguage\":\"${JELLYFIN_METADATA_LANGUAGE:-en}\"}"
  ADMIN_USER="$ADMIN_USER" JELLYFIN_ADMIN_PASSWORD="$JELLYFIN_ADMIN_PASSWORD" \
    python3 - "$base" <<'PY'
import json, os, sys, urllib.request
base = sys.argv[1]
body = json.dumps({"Name": os.environ["ADMIN_USER"],
                   "Password": os.environ["JELLYFIN_ADMIN_PASSWORD"]}).encode()
req = urllib.request.Request(base + "/Startup/User", data=body,
                             headers={"Content-Type": "application/json"},
                             method="POST")
urllib.request.urlopen(req).read()
PY
  curl -fsS -o /dev/null -X POST "$base/Startup/Complete"
  log "wizard completed; administrator '$ADMIN_USER' seeded"
  kill "$seed_pid"
  wait "$seed_pid" 2>/dev/null || true
  touch "$SEEDED_MARKER"
fi

# ------------------------------------------------------------- rotate
# Re-apply the credential on every boot so a redeploy is a working password
# reset. Jellyfin offers no other non-interactive path back into an instance.
if python3 /usr/local/lib/jellyfin-railway-seed.py rotate "$DB_PATH" "$ADMIN_USER"; then
  log "administrator credential re-applied from the environment"
else
  log "WARNING: could not re-apply the administrator credential"
fi

# ------------------------------------------------------ transcode threads
# EncodingThreadCount defaults to -1, which ffmpeg reads as the number of cores
# it can see -- the host's, not the cgroup's.
if [ -f "$CONFIG_DIR/encoding.xml" ] && [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r quota period < /sys/fs/cgroup/cpu.max || true
  if [ "${quota:-max}" != "max" ]; then
    cpus=$(( quota / period ))
    [ "$cpus" -lt 1 ] && cpus=1
    sed -i "s#<EncodingThreadCount>[-0-9]*</EncodingThreadCount>#<EncodingThreadCount>${cpus}</EncodingThreadCount>#" \
      "$CONFIG_DIR/encoding.xml"
    log "EncodingThreadCount set to ${cpus} (cgroup quota; host reports $(nproc))"
  fi
fi

write_network_xml "$PORT"
log "starting Jellyfin on port $PORT"
exec /jellyfin/jellyfin
