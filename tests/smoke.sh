#!/usr/bin/env bash
# End-to-end against the real game. The install directory lives in a volume
# seeded with an OLDER release, so the very first thing proven is the in-place
# update to the current stable (real download, real relaunch, same container,
# save carried across). Then: RCON → backup → live update check → SIGTERM
# saves. Webhooks go to a receiver in a sidecar container on a private network.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GAME_IMAGE:=factorio:test}"
: "${SMOKE_OLD_VERSION:=2.0.72}"
runner="${GAME_IMAGE}-runner"
name=factorio-smoke-$$
net="${name}-net"
vol="${name}-install"
hooks_ctr="${name}-hooks"
hook_port=18089
work=$(mktemp -d)
hooks="$work/webhooks.log"

cleanup() {
    docker rm -f "$name" "$hooks_ctr" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    docker volume rm "$vol" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "SMOKE FAIL: $*" >&2
    echo "--- container log ---" >&2; docker logs "$name" 2>&1 | tail -80 >&2 || true
    echo "--- webhooks ---" >&2; sync_hooks; cat "$hooks" >&2
    exit 1
}
step() { echo "==> $*"; }
sync_hooks() { docker logs "$hooks_ctr" 2>/dev/null > "$hooks" || true; }
wait_for() {
    local what=$1 pattern=$2 timeout=${3:-60} i
    for (( i = 0; i < timeout; i++ )); do
        sync_hooks; grep -qE "$pattern" "$hooks" && return 0; sleep 1
    done
    fail "timed out waiting for ${what}: /${pattern}/"
}
wait_for_log() {
    local pattern=$1 timeout=${2:-60} want=${3:-1} i
    for (( i = 0; i < timeout; i++ )); do
        (( $(docker logs "$name" 2>&1 | grep -cE "$pattern") >= want )) && return 0
        sleep 1
    done
    fail "timed out waiting for ${want}x log: /${pattern}/"
}
# Run a snippet inside the container with the toolkit and adapter loaded.
in_game() { docker exec "$name" bash -c "source /opt/gameops/shim/adapter.sh; adapter_load; $*"; }

step "build images"
[[ -n "$(docker images -q "$GAME_IMAGE")" ]] || docker build -q -t "$GAME_IMAGE" . >/dev/null
docker build -q -t "$runner" --build-arg "GAME_IMAGE=${GAME_IMAGE}" -f tests/runner.Dockerfile tests >/dev/null

step "start webhook receiver"
docker network create "$net" >/dev/null
docker run -d --name "$hooks_ctr" --network "$net" --entrypoint python3 "$runner" -u -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        print(body, flush=True)
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('0.0.0.0', ${hook_port}), H).serve_forever()
" >/dev/null
sleep 1

step "install ${SMOKE_OLD_VERSION} into a volume (the update's starting point)"
# A fresh named volume is seeded from the image's /opt/factorio, ownership
# included; the adapter's own installer then replaces it with the old release.
docker volume create "$vol" >/dev/null
docker run --rm -v "$vol:/opt/factorio" --entrypoint bash "$GAME_IMAGE" \
    -c "source /opt/gameops/shim/adapter.sh; adapter_load; factorio_install_version ${SMOKE_OLD_VERSION}" \
    || fail "could not install ${SMOKE_OLD_VERSION}"

step "run factorio ${SMOKE_OLD_VERSION}"
docker run -d --name "$name" --network "$net" -v "$vol:/opt/factorio" \
    -e "DISCORD_WEBHOOK_URL=http://${hooks_ctr}:${hook_port}/hook" \
    -e SERVER_NAME=Smoke -e RCON_PASSWORD=smoke-rcon \
    -e ADMINS=alice -e WHITELIST=alice,bob \
    -e UPDATE_ON_BOOT=false -e UPDATE_ENABLED=false -e UPDATE_WARN_MINUTES=0 \
    -e STOP_TIMEOUT=60 -e BACKUP_RETAIN_DAYS=0 -e LOG_LEVEL=debug \
    "$GAME_IMAGE" >/dev/null
wait_for "START notification" 'Smoke server is online' 300
[[ "$(in_game game_version)" == "$SMOKE_OLD_VERSION" ]] || fail "expected ${SMOKE_OLD_VERSION} installed, got $(in_game game_version)"

step "update in place to the current stable release"
# shellcheck disable=SC2016  # expanded inside the container, on purpose
latest=$(in_game 'http_get "$RELEASES_API" | json_get - .stable.headless')
[[ "$latest" =~ ^2\.[0-9]+\.[0-9]+$ ]] || fail "could not read the stable version from the releases API: '${latest}'"
[[ "$latest" != "$SMOKE_OLD_VERSION" ]] || fail "SMOKE_OLD_VERSION must be older than the current stable (${latest})"
echo "    ${SMOKE_OLD_VERSION} → ${latest}"
docker exec "$name" gameops update
wait_for "UPDATE_PRE notification" "Smoke server is updating to ${latest}" 30
wait_for "BACKUP_POST notification (pre-update)" 'Pre-update backup of the Smoke server complete: /backups/factorio-' 120
wait_for "UPDATE_POST notification" "Smoke server updated to ${latest}" 600
wait_for_log 'Smoke is ready' 300 2
[[ "$(docker inspect -f '{{.RestartCount}}' "$name")" == 0 ]] || fail "container restarted during the update"
[[ "$(docker inspect -f '{{.State.Running}}' "$name")" == true ]] || fail "container not running after the update"
[[ "$(in_game game_version)" == "$latest" ]] || fail "expected ${latest} after the update, got $(in_game game_version)"
docker exec "$name" test -x /opt/factorio/bin/x64/factorio || fail "binary missing after the update"
docker exec "$name" grep -qE 'Loading map .*world.zip' /data/logs/console.log || fail "the ${SMOKE_OLD_VERSION} save was not loaded by ${latest}"

step "health and RCON"
for i in $(seq 1 12); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" == healthy ]] && break
    sleep 5
done
[[ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" == healthy ]] || fail "container health is $(docker inspect -f '{{.State.Health.Status}}' "$name")"
version=$(in_game 'rcon /version' | tr -d '\r\n')
[[ "$version" =~ ^2\.[0-9]+\.[0-9]+ ]] || fail "RCON /version returned '${version}'"
echo "    version over RCON: ${version}"
[[ "$(in_game 'game_players')" == 0 ]] || fail "expected 0 players"
docker exec "$name" grep -q '"name": "Smoke"' /data/config/server-settings.json || fail "server-settings.json not rendered"
[[ "$(docker exec "$name" cat /data/config/server-whitelist.json)" == '["alice","bob"]' ]] || fail "whitelist not rendered"
docker exec "$name" grep -qE 'changing state from\(CreatingGame\) to\(InGame\)' /data/logs/console.log || fail "console log missing InGame transition"

step "backup"
docker exec "$name" gameops backup
[[ "$(docker exec "$name" gameops backup list | wc -l)" == 2 ]] || fail "expected the pre-update archive and this one"
archive=$(docker exec "$name" gameops backup list | head -1 | cut -f1)
docker exec "$name" gameops backup verify "$archive" | grep -q '^OK' || fail "backup verify failed"
docker exec "$name" tar -tzf "$archive" | grep -c '^saves/world.zip$' >/dev/null || fail "archive lacks saves/world.zip"
docker exec "$name" tar -tzf "$archive" | grep -c '^config/server-settings.json$' >/dev/null || fail "archive lacks config"

step "update check against the live releases API"
out=$(in_game 'CHANNEL=stable game_update_available; echo "rc=$?"')
[[ "$out" == *"rc=1"* ]] || fail "just updated, so stable must report current: ${out}"
exp=$(in_game 'CHANNEL=experimental game_update_available || true')
[[ "$exp" =~ ^2\.[0-9]+\.[0-9]+$ || -z "$exp" ]] || fail "experimental check returned '${exp}'"
echo "    experimental target: ${exp:-<current>}"

step "graceful stop on SIGTERM saves the world"
before=$(docker exec "$name" stat -c %Y /data/saves/world.zip)
sleep 1
docker stop -t 90 "$name" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
[[ "$code" == 0 ]] || fail "expected exit 0 after SIGTERM, got ${code}"
wait_for "STOP notification" 'Smoke server has shut down' 10
docker start "$name" >/dev/null 2>&1 || true   # only to read the volume
after=$(docker exec "$name" stat -c %Y /data/saves/world.zip 2>/dev/null || docker run --rm --volumes-from "$name" --entrypoint stat "$GAME_IMAGE" -c %Y /data/saves/world.zip)
docker stop -t 90 "$name" >/dev/null 2>&1 || true
(( after > before )) || fail "world.zip was not saved on shutdown (mtime ${before} → ${after})"

echo "SMOKE OK"
