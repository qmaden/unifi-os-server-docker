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
        "${COMPOSE[@]}" ps -a || true
        "${COMPOSE[@]}" exec -T unifi-os-server systemctl --no-pager status \
            unifi-core.service unifi.service nginx.service postgresql.service || true
        "${COMPOSE[@]}" logs --no-color --tail 80 || true
    fi
    "${COMPOSE[@]}" down -v || true
    # Bind-mounted data is owned by the container. The action runner cleans it up.
}
trap 'cleanup "$?"' EXIT

"${COMPOSE[@]}" pull unifi-os-server-mongodb
"${COMPOSE[@]}" up -d --pull never
container=$("${COMPOSE[@]}" ps -aq unifi-os-server)
for attempt in {1..60}; do
    status=()
    curl --noproxy '*' -kfsS --max-time 5 https://127.0.0.1:11443/ >/dev/null 2>&1 ||
        status+=("UniFi OS HTTPS")
    # The Network unit uses Type=notify and signals readiness after startup.
    "${COMPOSE[@]}" exec -T unifi-os-server systemctl is-active --quiet unifi.service >/dev/null 2>&1 ||
        status+=("UniFi Network")
    "${COMPOSE[@]}" exec -T unifi-os-server pg_isready -q >/dev/null 2>&1 ||
        status+=("PostgreSQL")
    if [ "${#status[@]}" -eq 0 ]; then
        echo "UniFi OS, UniFi Network, and PostgreSQL are ready."
        exit 0
    fi
    restarts=$(docker inspect --format '{{.RestartCount}}' "$container")
    if (( restarts >= 3 )); then
        echo "UniFi OS is restarting repeatedly." >&2
        exit 1
    fi
    if (( (attempt - 1) % 6 == 0 )); then
        printf 'Still waiting for %s.\n' "${status[*]}"
    fi
    sleep 5
done
echo "UniFi services did not become ready." >&2
exit 1
