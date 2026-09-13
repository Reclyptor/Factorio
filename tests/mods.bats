#!/usr/bin/env bats
load test_helper

setup()    { setup_adapter; stub_http; }
teardown() { teardown_adapter; }

@test "picks the newest release for the running game version" {
    [ "$(factorio_mod_pick_release "$(fixture mod-api.json)" 2.0)" = "2.0.3 even-distribution_2.0.3.zip /download/even-distribution/ccc" ]
    [ "$(factorio_mod_pick_release "$(fixture mod-api.json)" 1.1)" = "1.0.10 even-distribution_1.0.10.zip /download/even-distribution/aaa" ]
    [ -z "$(factorio_mod_pick_release "$(fixture mod-api.json)" 3.0)" ]
}

@test "built-in and ignored mods are never updated" {
    local ml="$TEST_TMP/mod-list.json"
    echo '{"mods":[{"name":"base","enabled":true},{"name":"space-age","enabled":true},{"name":"even-distribution","enabled":true},{"name":"disabled-one","enabled":false},{"name":"pinned","enabled":true}]}' > "$ml"
    export MODS_UPDATE_IGNORE="pinned"
    [ "$(factorio_mods_to_update "$ml")" = "even-distribution" ]
}

@test "mod updates need credentials and say so" {
    mkdir -p "$DATA_DIR/mods"; echo '{"mods":[{"name":"even-distribution","enabled":true}]}' > "$DATA_DIR/mods/mod-list.json"
    unset ACCOUNT_USERNAME ACCOUNT_TOKEN
    run factorio_update_mods
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs ACCOUNT_USERNAME and ACCOUNT_TOKEN"* ]]
    [ -z "$(cat "$HTTP_LOG")" ]
}
