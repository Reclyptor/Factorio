#!/usr/bin/env bash
# GameOps adapter for Factorio.
# Contract: https://github.com/Reclyptor/GameOps/blob/master/docs/CONTRACT.md
# shellcheck shell=bash
# shellcheck disable=SC2034  # GAME_* and GAME_CMD are consumed by the toolkit

GAME_NAME=factorio
GAME_DIR=${GAME_DIR:-/opt/factorio}
GAME_PORT=${PORT:-34197}
GAME_PORT_PROTO=udp
: "${RCON_PORT:=27015}"
: "${CHANNEL:=stable}"
: "${WORLD_NAME:=world}"
: "${LOAD_LATEST_SAVE:=true}"
: "${DLC_SPACE_AGE:=true}"
: "${MODS_UPDATE:=false}"

ADAPTER_DIR=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=adapter/lib/install.sh
source "${ADAPTER_DIR}/lib/install.sh"
# shellcheck source=adapter/lib/settings.sh
source "${ADAPTER_DIR}/lib/settings.sh"
# shellcheck source=adapter/lib/mods.sh
source "${ADAPTER_DIR}/lib/mods.sh"

SAVES_DIR="${DATA_DIR}/saves"
CONFIG_DIR="${DATA_DIR}/config"
MODS_DIR="${DATA_DIR}/mods"

# ── install / version / update ──────────────────────────────────────────────

game_install() {
    local d
    for d in saves config mods scenarios script-output logs; do
        mkdir -p "${DATA_DIR}/${d}"
    done

    # Map generation defaults come from the game itself; edit them on the volume.
    [[ -f "${CONFIG_DIR}/map-gen-settings.json" ]] || cp "${GAME_DIR}/data/map-gen-settings.example.json" "${CONFIG_DIR}/map-gen-settings.json"
    [[ -f "${CONFIG_DIR}/map-settings.json" ]]     || cp "${GAME_DIR}/data/map-settings.example.json" "${CONFIG_DIR}/map-settings.json"
    # The ban list is runtime state owned by the game: created once, never rendered.
    [[ -f "${CONFIG_DIR}/server-banlist.json" ]]   || echo '[]' > "${CONFIG_DIR}/server-banlist.json"

    # Incomplete saves from a forced exit would otherwise be picked as "latest".
    find "$SAVES_DIR" -maxdepth 1 -name '*.tmp.zip' -delete

    # Environment is the source of truth for these three (SPEC.md F2).
    factorio_render_server_settings "${ADAPTER_DIR}/templates/server-settings.json" "${CONFIG_DIR}/server-settings.json"
    factorio_render_list "${ADMINS:-}"    "${CONFIG_DIR}/server-adminlist.json"
    factorio_render_list "${WHITELIST:-}" "${CONFIG_DIR}/server-whitelist.json"
    factorio_apply_dlc "${MODS_DIR}/mod-list.json" "$DLC_SPACE_AGE"

    if is_true "$MODS_UPDATE"; then
        factorio_update_mods || log_warn "mod update failed; starting with the mods on disk"
    fi

    if [[ -z "${RCON_PASSWORD:-}" ]]; then
        RCON_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
        export RCON_PASSWORD
        log_warn "RCON_PASSWORD is not set; generated one for this run. Set it so backups run by hand and external tools can reach RCON."
    fi

    if [[ -z "$(find "$SAVES_DIR" -maxdepth 1 -name '*.zip' -print -quit)" ]]; then
        log_action "no save found; creating ${WORLD_NAME}.zip"
        local -a create=("${GAME_DIR}/bin/x64/factorio" --create "${SAVES_DIR}/${WORLD_NAME}.zip"
                         --map-gen-settings "${CONFIG_DIR}/map-gen-settings.json"
                         --map-settings "${CONFIG_DIR}/map-settings.json")
        [[ -n "${MAP_PRESET:-}" ]] && create+=(--preset "$MAP_PRESET")
        "${create[@]}" >/dev/null || { log_error "map generation failed"; return 1; }
    fi
}

game_version() { factorio_installed_version; }

game_update_available() {
    local json target current
    json=$(http_get "$RELEASES_API") || { log_warn "releases API unreachable"; return 1; }
    target=$(factorio_latest_from_json "$json" "$CHANNEL")
    [[ -n "$target" ]] || { log_warn "releases API had no ${CHANNEL} headless version"; return 1; }
    current=$(game_version)
    [[ "$target" != "$current" ]] || return 1
    printf '%s' "$target"
}

game_update_apply() { factorio_install_version "$1"; }

# ── process ─────────────────────────────────────────────────────────────────

game_start_cmd() {
    GAME_CMD=(
        "${GAME_DIR}/bin/x64/factorio"
        --port "$GAME_PORT"
        --server-settings "${CONFIG_DIR}/server-settings.json"
        --server-banlist "${CONFIG_DIR}/server-banlist.json"
        --server-adminlist "${CONFIG_DIR}/server-adminlist.json"
        --rcon-port "$RCON_PORT"
        --rcon-password "$RCON_PASSWORD"
        --server-id "${CONFIG_DIR}/server-id.json"
        --mod-directory "$MODS_DIR"
    )
    if [[ -n "${WHITELIST:-}" ]]; then
        GAME_CMD+=(--server-whitelist "${CONFIG_DIR}/server-whitelist.json" --use-server-whitelist)
    fi
    [[ -n "${BIND:-}" ]] && GAME_CMD+=(--bind "$BIND")
    if is_true "$LOAD_LATEST_SAVE"; then
        GAME_CMD+=(--start-server-load-latest)
    else
        GAME_CMD+=(--start-server "${SAVES_DIR}/${WORLD_NAME}.zip")
    fi
}

# Factorio binds RCON only once the map is loaded: the one true ready signal.
game_ready() { tcp_port_open 127.0.0.1 "$RCON_PORT"; }

game_shutdown() {
    rcon /server-save >/dev/null 2>&1 || log_warn "pre-shutdown save over RCON failed; the server also saves on SIGTERM"
    local pid
    pid=$(server_pid) || return 1
    kill -TERM "$pid"
}

# ── control ─────────────────────────────────────────────────────────────────

game_save()      { rcon /server-save >/dev/null; }
game_broadcast() { rcon "$*" >/dev/null; }

game_players() {
    local out
    out=$(rcon "/players online count" 2>/dev/null) || return 1
    factorio_parse_player_count "$out"
}

# "Online players (2):" or "Players (2): ..." → 2. Anything unparseable → 0.
factorio_parse_player_count() {
    local n
    n=$(printf '%s' "$1" | grep -oE '[0-9]+' | head -1)
    printf '%s' "${n:-0}"
}

# ── events ──────────────────────────────────────────────────────────────────

# Console lines look like:
#   2026-09-12 21:28:32 [JOIN] Alice joined the game
#   2026-09-12 21:40:01 [LEAVE] Alice left the game
factorio_parse_events() {
    sed -un \
        -e 's/^.*\[JOIN\] \(.*\) joined the game.*$/JOIN \1/p' \
        -e 's/^.*\[LEAVE\] \(.*\) left the game.*$/LEAVE \1/p'
}

game_events() { follow_log | factorio_parse_events; }

# ── backups ─────────────────────────────────────────────────────────────────

game_backup_paths() { printf '%s\n' saves config mods; }
