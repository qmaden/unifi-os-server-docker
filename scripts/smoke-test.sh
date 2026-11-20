#!/usr/bin/env bash
set -euo pipefail

export UNIFI_IMAGE="${1:?usage: smoke-test.sh IMAGE}"
export UOS_SYSTEM_IP=127.0.0.1
export MONGO_IMAGE=mongo:8.0
export MONGO_ACCEPT_EXISTING_DATA=false
export MONGO_DATA_DIR=./docker/mongodb

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d)
COMPOSE=(docker compose --project-directory "$TEMP" -f "$ROOT/docker-compose.yaml")
cleanup() {
    if [[ "$1" != 0 ]]; then
        "${COMPOSE[@]}" ps -a
        "${COMPOSE[@]}" logs --no-color --tail 80
    fi
    "${COMPOSE[@]}" down -v || true
    # Bind-mounted data is owned by the container. The action runner cleans it up.
}
trap 'cleanup "$?"' EXIT

"${COMPOSE[@]}" pull unifi-os-server-mongodb
"${COMPOSE[@]}" up -d --pull never
for attempt in {1..90}; do
    if curl --noproxy '*' -kfsS --max-time 5 https://127.0.0.1:11443/ >/dev/null 2>&1 &&
       curl --noproxy '*' -kfsS --max-time 5 https://127.0.0.1:8443/status >/dev/null 2>&1 &&
       "${COMPOSE[@]}" exec -T unifi-os-server pg_isready -q; then
        echo "UniFi OS, UniFi Network, and PostgreSQL are ready."
        exit 0
    fi
    sleep 5
done
echo "UniFi services did not become ready." >&2
exit 1
