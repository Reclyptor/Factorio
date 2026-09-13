#!/usr/bin/env bats
load test_helper

setup()    { setup_adapter; }
teardown() { teardown_adapter; }

@test "renders server-settings.json from the environment" {
    export SERVER_NAME="Test Factory" SERVER_DESCRIPTION="Space Age" \
           TAGS="friends, space age" MAX_PLAYERS=8 GAME_PASSWORD=example-pass \
           AUTOSAVE_INTERVAL=5 LAN=false
    factorio_render_server_settings /opt/game/templates/server-settings.json "$TEST_TMP/s.json"
    [ "$(json_get "$TEST_TMP/s.json" .name)" = "Test Factory" ]
    [ "$(json_get "$TEST_TMP/s.json" .description)" = "Space Age" ]
    [ "$(json_get "$TEST_TMP/s.json" .tags)" = '["friends","space age"]' ]
    [ "$(json_get "$TEST_TMP/s.json" .max_players)" = 8 ]
    [ "$(json_get "$TEST_TMP/s.json" .game_password)" = example-pass ]
    [ "$(json_get "$TEST_TMP/s.json" .autosave_interval)" = 5 ]
    [ "$(json_get "$TEST_TMP/s.json" .visibility.public)" = false ]
    [ "$(json_get "$TEST_TMP/s.json" .visibility.lan)" = false ]
    # untouched keys keep the template value
    [ "$(json_get "$TEST_TMP/s.json" .allow_commands)" = admins-only ]
    [ "$(json_get "$TEST_TMP/s.json" .require_user_verification)" = true ]
    [ "$(json_get "$TEST_TMP/s.json" .minimum_segment_size)" = 25 ]
}

@test "defaults match the template when nothing is set" {
    factorio_render_server_settings /opt/game/templates/server-settings.json "$TEST_TMP/s.json"
    for key in name description tags max_players game_password autosave_interval autosave_slots allow_commands auto_pause maximum_segment_size; do
        [ "$(json_get "$TEST_TMP/s.json" ".$key")" = "$(json_get /opt/game/templates/server-settings.json ".$key")" ]
    done
}

@test "lists parse commas, trim whitespace and drop empties" {
    [ "$(factorio_list_json 'alice, bob ,,  carol')" = '["alice","bob","carol"]' ]
    [ "$(factorio_list_json '')" = '[]' ]
    factorio_render_list "alice,bob" "$TEST_TMP/admins.json"
    [ "$(cat "$TEST_TMP/admins.json")" = '["alice","bob"]' ]
}

@test "DLC toggles create and edit mod-list.json" {
    local ml="$TEST_TMP/mod-list.json"
    enabled_mods() { local i n e out=""; for (( i = 0; ; i++ )); do n=$(json_get "$ml" ".mods[$i].name") || break; e=$(json_get "$ml" ".mods[$i].enabled"); [[ "$e" == true ]] && out+="$n "; done; printf '%s' "${out% }"; }
    factorio_apply_dlc "$ml" true
    [ "$(enabled_mods)" = "base elevated-rails quality space-age" ]
    factorio_apply_dlc "$ml" false
    [ "$(enabled_mods)" = "base" ]
    factorio_apply_dlc "$ml" "quality elevated-rails"
    [ "$(enabled_mods)" = "base elevated-rails quality" ]
    # third-party entries are left alone
    json_set "$ml" ".mods[4]" '{"name":"even-distribution","enabled":true}' --raw
    factorio_apply_dlc "$ml" true
    [ "$(json_get "$ml" '.mods[4].enabled')" = true ]
    [ "$(json_get "$ml" '.mods[4].name')" = even-distribution ]
}

@test "game_install renders config, lists and DLC and creates a save" {
    export ADMINS="alice" WHITELIST="alice,bob" DLC_SPACE_AGE=false
    game_install
    [ "$(json_get "$DATA_DIR/config/server-settings.json" .name)" = "Factorio" ]
    [ "$(cat "$DATA_DIR/config/server-adminlist.json")" = '["alice"]' ]
    [ "$(cat "$DATA_DIR/config/server-whitelist.json")" = '["alice","bob"]' ]
    [ "$(cat "$DATA_DIR/config/server-banlist.json")" = '[]' ]
    [ -f "$DATA_DIR/config/map-gen-settings.json" ]
    [ -f "$DATA_DIR/config/map-settings.json" ]
    local idx; idx=$(factorio_mod_index "$DATA_DIR/mods/mod-list.json" space-age)
    [ "$(json_get "$DATA_DIR/mods/mod-list.json" ".mods[$idx].enabled")" = false ]
    [ -f "$DATA_DIR/saves/world.zip" ]
}

@test "game_install never overwrites the ban list or an existing save" {
    mkdir -p "$DATA_DIR/config" "$DATA_DIR/saves"
    echo '["griefer"]' > "$DATA_DIR/config/server-banlist.json"
    echo "not a real save" > "$DATA_DIR/saves/mine.zip"
    game_install
    [ "$(cat "$DATA_DIR/config/server-banlist.json")" = '["griefer"]' ]
    [ ! -f "$DATA_DIR/saves/world.zip" ]
    [ "$(cat "$DATA_DIR/saves/mine.zip")" = "not a real save" ]
}

@test "game_install clears .tmp.zip leftovers" {
    mkdir -p "$DATA_DIR/saves"
    touch "$DATA_DIR/saves/_autosave1.tmp.zip"
    game_install
    [ ! -e "$DATA_DIR/saves/_autosave1.tmp.zip" ]
}

@test "start command reflects whitelist, bind and save selection" {
    export WHITELIST="" LOAD_LATEST_SAVE=true
    game_start_cmd
    [[ " ${GAME_CMD[*]} " == *" --start-server-load-latest "* ]]
    [[ " ${GAME_CMD[*]} " != *"--use-server-whitelist"* ]]
    [[ " ${GAME_CMD[*]} " == *" --rcon-password test-rcon "* ]]

    export WHITELIST="alice" BIND=10.0.0.5 LOAD_LATEST_SAVE=false WORLD_NAME=mine
    game_start_cmd
    [[ " ${GAME_CMD[*]} " == *" --use-server-whitelist "* ]]
    [[ " ${GAME_CMD[*]} " == *" --bind 10.0.0.5 "* ]]
    [[ " ${GAME_CMD[*]} " == *" --start-server ${DATA_DIR}/saves/mine.zip "* ]]
}
