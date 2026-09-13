#!/usr/bin/env bash
# Render Factorio's JSON configuration from the environment.
# shellcheck shell=bash

# A comma-separated list → a JSON array of trimmed, non-empty strings.
factorio_list_json() {
    local -a items=()
    local part
    IFS=',' read -ra parts <<< "${1:-}"
    for part in "${parts[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [[ -n "$part" ]] && items+=("$part")
    done
    json_array "${items[@]}"
}

# factorio_render_server_settings <template> <destination>
# Every FACTORIO_* setting has a default matching the template so an unset
# variable leaves the template's value in place.
factorio_render_server_settings() {
    local template=$1 dest=$2
    local tmp="${dest}.tmp"
    cp "$template" "$tmp"
    json_set "$tmp" .name        "${SERVER_NAME:-Factorio}"
    json_set "$tmp" .description "${SERVER_DESCRIPTION:-}"
    json_set "$tmp" .tags        "$(factorio_list_json "${TAGS:-}")" --raw
    json_set "$tmp" .max_players "${MAX_PLAYERS:-0}" --raw
    json_set "$tmp" .visibility.public "${PUBLIC:-false}" --raw
    json_set "$tmp" .visibility.lan    "${LAN:-true}" --raw
    json_set "$tmp" .username      "${ACCOUNT_USERNAME:-}"
    json_set "$tmp" .token         "${ACCOUNT_TOKEN:-}"
    json_set "$tmp" .game_password "${GAME_PASSWORD:-}"
    json_set "$tmp" .require_user_verification "${REQUIRE_USER_VERIFICATION:-true}" --raw
    json_set "$tmp" .max_upload_in_kilobytes_per_second "${MAX_UPLOAD_KBPS:-0}" --raw
    json_set "$tmp" .max_upload_slots "${MAX_UPLOAD_SLOTS:-5}" --raw
    json_set "$tmp" .minimum_latency_in_ticks "${MIN_LATENCY_TICKS:-0}" --raw
    json_set "$tmp" .max_heartbeats_per_second "${MAX_HEARTBEATS:-60}" --raw
    json_set "$tmp" .ignore_player_limit_for_returning_players "${IGNORE_PLAYER_LIMIT_FOR_RETURNING:-false}" --raw
    json_set "$tmp" .allow_commands "${ALLOW_COMMANDS:-admins-only}"
    json_set "$tmp" .autosave_interval "${AUTOSAVE_INTERVAL:-10}" --raw
    json_set "$tmp" .autosave_slots    "${AUTOSAVE_SLOTS:-5}" --raw
    json_set "$tmp" .afk_autokick_interval "${AFK_AUTOKICK_INTERVAL:-0}" --raw
    json_set "$tmp" .auto_pause "${AUTO_PAUSE:-true}" --raw
    json_set "$tmp" .auto_pause_when_players_connect "${AUTO_PAUSE_WHEN_PLAYERS_CONNECT:-false}" --raw
    json_set "$tmp" .only_admins_can_pause_the_game "${ONLY_ADMINS_CAN_PAUSE:-true}" --raw
    json_set "$tmp" .autosave_only_on_server "${AUTOSAVE_ONLY_ON_SERVER:-true}" --raw
    json_set "$tmp" .non_blocking_saving "${NON_BLOCKING_SAVING:-false}" --raw
    mv "$tmp" "$dest"
}

# factorio_render_list <comma list> <destination>   (admin list, whitelist)
factorio_render_list() {
    factorio_list_json "$1" > "${2}.tmp" && mv "${2}.tmp" "$2"
}

# Index of a mod in mod-list.json, or -1.
factorio_mod_index() {
    local file=$1 name=$2 i n
    for (( i = 0; ; i++ )); do
        n=$(json_get "$file" ".mods[$i].name") || return 1
        [[ "$n" == "$name" ]] && { printf '%s' "$i"; return 0; }
    done
}

factorio_mod_count() {
    local file=$1 i
    for (( i = 0; ; i++ )); do
        json_get "$file" ".mods[$i].name" >/dev/null || { printf '%s' "$i"; return 0; }
    done
}

# Enable or disable the Space Age mods in mod-list.json.
#   DLC_SPACE_AGE=true    all three on
#   DLC_SPACE_AGE=false   all three off
#   DLC_SPACE_AGE="quality elevated-rails"   just those
factorio_apply_dlc() {
    local mod_list=$1 setting=${2:-true}
    [[ -f "$mod_list" ]] || printf '{"mods":[{"name":"base","enabled":true}]}\n' > "$mod_list"
    local mod enabled idx
    for mod in elevated-rails quality space-age; do
        case "${setting,,}" in
            true)  enabled=true ;;
            false) enabled=false ;;
            *) if [[ " ${setting} " == *" ${mod} "* ]]; then enabled=true; else enabled=false; fi ;;
        esac
        if idx=$(factorio_mod_index "$mod_list" "$mod"); then
            json_set "$mod_list" ".mods[$idx].enabled" "$enabled" --raw
        else
            idx=$(factorio_mod_count "$mod_list")
            json_set "$mod_list" ".mods[$idx]" "{\"name\":$(json_escape "$mod"),\"enabled\":$enabled}" --raw
        fi
    done
}
