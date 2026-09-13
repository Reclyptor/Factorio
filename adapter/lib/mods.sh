#!/usr/bin/env bash
# Mod portal updates. Downloads need a factorio.com username and token
# (ACCOUNT_USERNAME / ACCOUNT_TOKEN); the metadata API does not.
# shellcheck shell=bash

MOD_API=${MOD_API:-https://mods.factorio.com/api/mods}
MOD_PORTAL=${MOD_PORTAL:-https://mods.factorio.com}
BUILTIN_MODS="base elevated-rails quality space-age"

# From a mod's API JSON, the newest release for a game major.minor:
# prints "<version> <file_name> <download_url>", or nothing.
#   factorio_mod_pick_release <json> <game major.minor>
factorio_mod_pick_release() {
    local json=$1 gv=$2 i fv released best_released="" best=""
    for (( i = 0; ; i++ )); do
        fv=$(printf '%s' "$json" | json_get - ".releases[$i].info_json.factorio_version") || break
        [[ "$fv" == "$gv" ]] || continue
        released=$(printf '%s' "$json" | json_get - ".releases[$i].released_at")
        if [[ "$released" > "$best_released" ]]; then
            best_released=$released
            best="$(printf '%s' "$json" | json_get - ".releases[$i].version") $(printf '%s' "$json" | json_get - ".releases[$i].file_name") $(printf '%s' "$json" | json_get - ".releases[$i].download_url")"
        fi
    done
    [[ -n "$best" ]] && printf '%s' "$best"
}

# Enabled mods from mod-list.json, excluding the game's own.
factorio_mods_to_update() {
    local mod_list=$1 i name enabled
    for (( i = 0; ; i++ )); do
        name=$(json_get "$mod_list" ".mods[$i].name") || break
        enabled=$(json_get "$mod_list" ".mods[$i].enabled")
        [[ "$enabled" == true ]] || continue
        [[ " ${BUILTIN_MODS} " == *" ${name} "* ]] && continue
        [[ " ${MODS_UPDATE_IGNORE:-} " == *" ${name} "* ]] && continue
        printf '%s\n' "$name"
    done
}

factorio_update_mods() {
    local mod_list="${MODS_DIR}/mod-list.json"
    [[ -f "$mod_list" ]] || return 0
    if [[ -z "${ACCOUNT_USERNAME:-}" || -z "${ACCOUNT_TOKEN:-}" ]]; then
        log_warn "MODS_UPDATE needs ACCOUNT_USERNAME and ACCOUNT_TOKEN; skipping"
        return 0
    fi
    local gv name json pick version file url installed
    gv=$(game_version | cut -d. -f1,2)
    while read -r name; do
        json=$(http_get "${MOD_API}/${name}") || { log_warn "mod portal: ${name} lookup failed"; continue; }
        pick=$(factorio_mod_pick_release "$json" "$gv")
        [[ -n "$pick" ]] || { log_warn "mod portal: no ${name} release for Factorio ${gv}"; continue; }
        read -r version file url <<<"$pick"
        installed=$(find "$MODS_DIR" -maxdepth 1 -name "${name}_*.zip" -printf '%f\n' | sort -V | tail -1)
        [[ "$installed" == "$file" ]] && continue
        log_info "mod ${name}: ${installed:-none} → ${version}"
        if http_get -o "${MODS_DIR}/${file}.part" \
                "${MOD_PORTAL}${url}?username=${ACCOUNT_USERNAME}&token=${ACCOUNT_TOKEN}"; then
            find "$MODS_DIR" -maxdepth 1 -name "${name}_*.zip" -delete
            mv "${MODS_DIR}/${file}.part" "${MODS_DIR}/${file}"
        else
            rm -f "${MODS_DIR}/${file}.part"
            log_warn "mod ${name}: download failed; keeping ${installed:-nothing}"
        fi
    done < <(factorio_mods_to_update "$mod_list")
}
