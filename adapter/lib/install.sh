#!/usr/bin/env bash
# Installation, versioning and updates of the game binary.
# shellcheck shell=bash

RELEASES_API=${RELEASES_API:-https://factorio.com/api/latest-releases}
DOWNLOAD_BASE=${DOWNLOAD_BASE:-https://www.factorio.com/get-download}

# The game reads config/config.ini next to its binaries; write-data there is
# what sends saves, mods and config to DATA_DIR.
factorio_write_config_ini() {
    local install_dir=$1 write_data=$2
    mkdir -p "${install_dir}/config"
    cat > "${install_dir}/config/config.ini" <<INI
[path]
read-data=__PATH__executable__/../../data
write-data=${write_data}

[general]
locale=
INI
}

# "Version: 2.0.77 (build 84539, linux64, headless)" → 2.0.77
factorio_parse_version() {
    sed -n 's/^Version: \([0-9][0-9.]*\).*/\1/p' | head -1
}

factorio_installed_version() {
    "${GAME_DIR}/bin/x64/factorio" --version 2>/dev/null | factorio_parse_version
}

# Latest version for the configured channel from the releases API JSON.
#   factorio_latest_from_json <json> [channel]
factorio_latest_from_json() {
    local json=$1 channel=${2:-stable}
    printf '%s' "$json" | json_get - ".${channel}.headless" 2>/dev/null || true
}

# Download <version> and replace the installation in place.
factorio_install_version() {
    local version=$1
    local tmp
    tmp=$(mktemp -d)
    log_info "downloading Factorio ${version}"
    if ! http_get -o "${tmp}/factorio.tar.xz" "${DOWNLOAD_BASE}/${version}/headless/linux64"; then
        rm -rf "$tmp"; log_error "download failed"; return 1
    fi
    if ! xz -t "${tmp}/factorio.tar.xz"; then
        rm -rf "$tmp"; log_error "downloaded archive is corrupt"; return 1
    fi
    # Extract next to the install first so a bad archive never leaves a
    # half-replaced game behind.
    mkdir -p "${tmp}/extract"
    if ! tar -xJf "${tmp}/factorio.tar.xz" --strip-components=1 -C "${tmp}/extract"; then
        rm -rf "$tmp"; log_error "extract failed"; return 1
    fi
    find "$GAME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "${tmp}/extract/." "$GAME_DIR/"
    rm -rf "$tmp"
    factorio_write_config_ini "$GAME_DIR" "$DATA_DIR"
    local now
    now=$(factorio_installed_version)
    [[ "$now" == "$version" ]] || { log_error "installed ${now}, expected ${version}"; return 1; }
}
