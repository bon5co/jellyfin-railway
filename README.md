# jellyfin-railway

Wrapper image around [`jellyfin/jellyfin`](https://hub.docker.com/r/jellyfin/jellyfin)
for the Railway template, pinned to **10.11.11**.

Upstream's image is fine on Docker Compose and wrong on Railway in three ways.

### 1. Nothing persists unless the volume covers `/config` and `/cache`

The image declares two volumes and writes everything durable into them:

    JELLYFIN_DATA_DIR=/config      # jellyfin.db, library.db, metadata, plugins
    JELLYFIN_CONFIG_DIR=/config/config
    JELLYFIN_LOG_DIR=/config/log
    JELLYFIN_CACHE_DIR=/cache

A Railway template mounts exactly one volume, so this image re-points the whole
tree at `/data`. A template that mounts `/data` without moving these variables
keeps its accounts, libraries, watch history and plugins on the container's
disposable layer.

### 2. The setup wizard authenticates nobody

`GET /Startup/User`, `POST /Startup/Configuration`, `POST /Startup/User` and
`POST /Startup/Complete` are open to any caller until the wizard is completed,
and the account the wizard creates is an administrator. On a public URL, the
first stranger to reach a fresh instance owns it.

The entrypoint therefore completes the wizard against a loopback port that the
platform does not route, before the public port is ever bound, and refuses to
start when `JELLYFIN_ADMIN_PASSWORD` is empty.

### 3. Jellyfin ignores `$PORT`

The listen port lives in `network.xml` (`InternalHttpPort`), which the image
does not ship at all — it is written the first time a network setting changes.
The entrypoint writes it on every boot from `$PORT`.

## Also

- **Password rotation.** Jellyfin exposes no non-interactive way to set a
  password, so an instance whose credential is lost cannot be recovered. The
  entrypoint re-applies `JELLYFIN_ADMIN_PASSWORD` to `jellyfin.db` on every
  boot (PBKDF2-SHA512, the same format Jellyfin writes), which makes a redeploy
  a working password reset.
- **Transcode threads.** `EncodingThreadCount` defaults to `-1`, which ffmpeg
  reads as the number of cores it can see — the host's, not the container's.
  The entrypoint sizes it from `/sys/fs/cgroup/cpu.max`.
- **Published server URL** is set from `RAILWAY_PUBLIC_DOMAIN` so clients and
  shared links resolve to the deployment's own domain.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `JELLYFIN_ADMIN_PASSWORD` | — | Required. The container refuses to start without it. |
| `JELLYFIN_ADMIN_USERNAME` | `admin` | |
| `JELLYFIN_UI_CULTURE` | `en-US` | |
| `JELLYFIN_METADATA_LANGUAGE` | `en` | |
| `JELLYFIN_METADATA_COUNTRY` | `US` | |
| `PORT` | `8096` | Injected by the platform. |

Mount the volume at `/data`.
