# Factorio

A self-contained Factorio headless server image — Space Age included — with scheduled backups,
in-place auto-updates that warn players first, Discord notifications, player join/leave events,
a whitelist and admin list driven by configuration, and RCON that is actually wired to the
environment. Built on the [GameOps](https://github.com/Reclyptor/GameOps) toolkit.

```sh
mkdir -p data backups && sudo chown -R 845:845 data backups
docker run -d --name factorio -p 34197:34197/udp \
  -e SERVER_NAME="My Factory" -e ADMINS=you -e WHITELIST=you,friend \
  -e GAME_PASSWORD=secret -e RCON_PASSWORD=secret2 -e DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/… \
  -v "$PWD/data:/data" -v "$PWD/backups:/backups" \
  ghcr.io/reclyptor/factorio:latest
```

Or use [`compose.yaml`](compose.yaml). A fresh map is generated on first start; an existing
data volume with Factorio's own layout (`saves/ mods/ config/`) owned by uid 845 is picked up as is.

## What it does for you

| | |
|---|---|
| **Backups** | Nightly by default: `/server-save` over RCON, then `saves/`, `config/` and `mods/` into `/backups/factorio-<timestamp>.tar.gz`, pruned after `BACKUP_RETAIN_DAYS`. `docker exec factorio gameops-backup` any time. |
| **Updates** | Hourly check against factorio.com's stable channel. When a release lands: players are warned in-game at 15/10/5/2/1 min, a backup is taken, the world is saved, the new headless tarball is verified and installed, and the server relaunches **inside the same container**. |
| **Notifications** | Discord: online, offline, crashed, updating/updated, backup, join, leave. Plain text, every message overridable. |
| **Access control** | `WHITELIST` (factorio.com usernames, verified by the auth server) is the real lock; `GAME_PASSWORD` is optional on top. `ADMINS` get console commands. |
| **Lifecycle** | Graceful stop on `SIGTERM` (`/server-save`, then Factorio's own save-on-exit). Crashes exit the container with the game's code. Health check with no RCON noise. |

## Configuration

### Factorio

| Variable | Default | Meaning |
|---|---|---|
| `SERVER_NAME` | `Factorio` | One name for both jobs: the in-game server name (browser, `/server-settings`) and the name every Discord notification uses. |
| `SERVER_DESCRIPTION` | — | |
| `MAX_PLAYERS` | `0` | `0` = unlimited. |
| `GAME_PASSWORD` | — | Join password. |
| `ADMINS` | — | Comma-separated factorio.com usernames → `server-adminlist.json`. |
| `WHITELIST` | — | Comma-separated usernames. Non-empty turns the whitelist on. |
| `WORLD_NAME` | `world` | Name of the save created on first start (and loaded when `LOAD_LATEST_SAVE=false`). |
| `PUBLIC` / `LAN` | `false` / `true` | Public listing needs `ACCOUNT_USERNAME` and `ACCOUNT_TOKEN`. |
| `TAGS` | — | Comma-separated. |
| `ACCOUNT_USERNAME` / `ACCOUNT_TOKEN` | — | factorio.com credentials; used for public listing and mod-portal downloads. |
| `REQUIRE_USER_VERIFICATION` | `true` | Verify joining players against factorio.com. |
| `AUTOSAVE_INTERVAL` / `_SLOTS` | `10` / `5` | Minutes between autosaves; rotating slots. |
| `AUTO_PAUSE` | `true` | Pause when empty. |
| `ALLOW_COMMANDS` | `admins-only` | `true` / `false` / `admins-only`. |
| `AFK_AUTOKICK_INTERVAL` | `0` | Minutes; `0` disables. |
| `LOAD_LATEST_SAVE` | `true` | Load the newest save (including autosaves) on start. |
| `MAP_PRESET` | — | Map-gen preset for the first save (`rail-world`, `death-world`, …). |
| `DLC_SPACE_AGE` | `true` | `true`, `false`, or a subset: `"quality elevated-rails"`. |
| `MODS_UPDATE` | `false` | Refresh installed mods from the mod portal at boot (needs username + token). |
| `MODS_UPDATE_IGNORE` | — | Space-separated mod names to leave alone. |
| `CHANNEL` | `stable` | `stable` or `experimental` for updates. |
| `BIND` | — | Bind address. |
| `PORT` | `34197` | Game port (UDP). |
| `RCON_PORT` / `RCON_PASSWORD` | `27015` / *(generated)* | Set `RCON_PASSWORD`; a generated one only lasts the container's lifetime. |

Further settings (`max_upload_in_kilobytes_per_second`, segment sizes, …) keep the game's
defaults; see [`adapter/templates/server-settings.json`](adapter/templates/server-settings.json)
and [`adapter/lib/settings.sh`](adapter/lib/settings.sh) for the full mapping.

**The environment is the source of truth** for `server-settings.json`, the admin list and the
whitelist — they are re-rendered on every start, so in-game `/promote` and `/whitelist add` do not
survive a restart. Edit the variables instead. The ban list (`/ban`) is the game's own and is kept.
`map-gen-settings.json` and `map-settings.json` live on the volume under `config/` and are yours
to edit before the first save is generated.

### Backups, updates, notifications

These are the [GameOps](https://github.com/Reclyptor/GameOps#configuration) variables and are
identical across every Reclyptor game image: `BACKUP_CRON`, `BACKUP_RETAIN_DAYS`,
`BACKUP_ON_UPDATE`, `UPDATE_CRON`, `UPDATE_ON_BOOT`, `UPDATE_WARN_MINUTES`,
`UPDATE_SKIP_IF_PLAYERS`, `STOP_TIMEOUT`, `METRICS_PORT`, `DISCORD_WEBHOOK_URL`,
`DISCORD_<EVENT>_MESSAGE`, `TZ`, … Backups are verified as they are written; `gameops backup list`,
`gameops backup verify latest` and `gameops restore latest` work from `docker exec`.

## Volumes and ports

| | |
|---|---|
| `/data` | `saves/ mods/ config/ scenarios/ script-output/ logs/` — uid/gid **845** |
| `/backups` | Archives. Mount a NAS share here for off-box copies. |
| `34197/udp` | Game |
| `27015/tcp` | RCON — do not publish it; `docker exec factorio gameops rcon /players` |
| `9110/tcp` | `/metrics` (Prometheus) and `/healthz` — `METRICS_PORT`, `0` disables |

## Development

```sh
tests/run.sh      # bats, inside the built image
tests/smoke.sh    # real server: older release → update in place → RCON → backup → SIGTERM save
                  # SMOKE_OLD_VERSION picks the starting release (default 2.0.72)
```

## License

MIT.
