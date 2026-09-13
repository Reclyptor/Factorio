#!/usr/bin/env bats
load test_helper

setup()    { setup_adapter; }
teardown() { teardown_adapter; }

@test "console lines become JOIN/LEAVE events and nothing else" {
    run factorio_parse_events < /tests/fixtures/console.log
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "JOIN Alice" ]
    [ "${lines[1]}" = "JOIN Bob Builder" ]
    [ "${lines[2]}" = "LEAVE Alice" ]
    [ "${lines[3]}" = "LEAVE Bob Builder" ]
    [ "${#lines[@]}" -eq 4 ]
}

@test "player count parsing" {
    [ "$(factorio_parse_player_count 'Online players (2):')" = 2 ]
    [ "$(factorio_parse_player_count 'Players (0):')" = 0 ]
    [ "$(factorio_parse_player_count '')" = 0 ]
}

@test "backup paths" {
    [ "$(game_backup_paths | tr '\n' ' ')" = "saves config mods " ]
}
