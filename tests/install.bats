#!/usr/bin/env bats
load test_helper

setup()    { setup_adapter; stub_http; }
teardown() { teardown_adapter; }

@test "parses the version line" {
    [ "$(fixture version.txt | factorio_parse_version)" = 2.0.77 ]
}

@test "the installed game reports its version" {
    [[ "$(game_version)" =~ ^2\.[0-9]+\.[0-9]+$ ]]
}

@test "picks the headless version for the channel" {
    [ "$(factorio_latest_from_json "$(fixture latest-releases.json)" stable)" = 2.0.77 ]
    [ "$(factorio_latest_from_json "$(fixture latest-releases.json)" experimental)" = 2.1.17 ]
    [ -z "$(factorio_latest_from_json '{}' stable)" ]
}

@test "update available only when the channel is ahead" {
    export HTTP_STUB_FILE=/tests/fixtures/latest-releases.json
    export CHANNEL=stable
    if [ "$(game_version)" = 2.0.77 ]; then
        run game_update_available
        [ "$status" -eq 1 ]
    fi
    export CHANNEL=experimental
    run game_update_available
    [ "$status" -eq 0 ]
    [ "$output" = 2.1.17 ]
}

@test "an unreachable releases API is reported as current" {
    export HTTP_STUB_EXIT=1
    run game_update_available
    [ "$status" -eq 1 ]
}

@test "config.ini points write-data at the data dir" {
    factorio_write_config_ini "$TEST_TMP/inst" /somewhere/data
    grep -q '^write-data=/somewhere/data$' "$TEST_TMP/inst/config/config.ini"
    grep -q '^read-data=__PATH__executable__/../../data$' "$TEST_TMP/inst/config/config.ini"
}

@test "a corrupt download never touches the installation" {
    export GAME_DIR="$TEST_TMP/game"
    mkdir -p "$GAME_DIR/bin/x64"; echo keep > "$GAME_DIR/bin/x64/factorio"
    echo "not xz" > "$TEST_TMP/bad.tar.xz"
    export HTTP_STUB_FILE="$TEST_TMP/bad.tar.xz"
    run factorio_install_version 9.9.9
    [ "$status" -eq 1 ]
    [ "$(cat "$GAME_DIR/bin/x64/factorio")" = keep ]
}
