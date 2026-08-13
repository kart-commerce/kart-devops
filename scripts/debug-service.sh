#!/usr/bin/env bash
# Lets ONE backend service be debugged locally (e.g. in Rider, on its usual ports.env port)
# while every other service keeps running in Docker and keeps addressing it exactly the same
# way it always has -- via its Docker DNS name (e.g. "identity" in compose/globalconfig/global.json's
# "http://identity:8080" URLs).
#
# Why this is needed: a container's `localhost` is its own network namespace, not the host
# machine's. Stopping a service's container to run it in Rider instead breaks every other
# container's calls to it, because the Docker DNS name (e.g. "identity") no longer resolves to
# anything. Editing every dependent service's config to point elsewhere isn't maintainable and
# has to be undone every time.
#
# What this does instead: stop the target's container, then start a tiny `socat` container in
# its place that keeps its Docker DNS name/network alias (so `http://identity:8080` still
# resolves for every other container, unchanged) and forwards all traffic to host.docker.internal
# on the same port Rider's launchSettings.json already runs it on. No other service's config is
# touched.
#
# Usage:
#   scripts/debug-service.sh identity              # swap identity's container for a passthrough
#   scripts/debug-service.sh identity --port 9001   # forward to a non-default local port instead
#   scripts/debug-service.sh identity --restore     # tear down the passthrough, restart the real container
#   scripts/debug-service.sh --list                 # show valid service names
#
# Then run the service in Rider (its launchSettings.json applicationUrl already matches
# ports.env's <NAME>_PORT -- see README.md's Ports table) and hit debug as normal.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Mirrors docker-compose.yml's backend service list (see its own "13 real, scaffolded services"
# comment) -- add a name here once a new service is scaffolded and added there.
VALID_SERVICES=(identity category user product search inventory cart order payment offer wishlist notification delivery-tracking admin)

usage() {
  echo "Usage: $0 <service> [--port N] | $0 <service> --restore | $0 --list" >&2
  exit 1
}

is_valid_service() {
  local svc="$1"
  for s in "${VALID_SERVICES[@]}"; do
    [[ "$s" == "$svc" ]] && return 0
  done
  return 1
}

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' "${VALID_SERVICES[@]}"
  exit 0
fi

SERVICE="${1:-}"
[[ -z "$SERVICE" ]] && usage
is_valid_service "$SERVICE" || { echo "Unknown service '$SERVICE'. Valid: ${VALID_SERVICES[*]}" >&2; exit 1; }
shift

RESTORE=false
LOCAL_PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore) RESTORE=true; shift ;;
    --port) LOCAL_PORT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

CONTAINER_NAME="kart-$SERVICE"
PASSTHROUGH_NAME="kart-$SERVICE-passthrough"

set -a
source ports.env
set +a

# ports.env names each var <SERVICE>_PORT with hyphens turned to underscores (e.g.
# delivery-tracking -> DELIVERY_TRACKING_PORT) -- same convention docker-compose.yml's
# `${..._PORT}` interpolation relies on.
PORT_VAR="$(echo "$SERVICE" | tr '-' '_' | tr '[:lower:]' '[:upper:]')_PORT"
DEFAULT_PORT="${!PORT_VAR:-}"
[[ -z "$DEFAULT_PORT" ]] && { echo "Couldn't find $PORT_VAR in ports.env" >&2; exit 1; }
LOCAL_PORT="${LOCAL_PORT:-$DEFAULT_PORT}"

if $RESTORE; then
  echo "Removing passthrough for '$SERVICE' and restoring its real container..."
  docker rm -f "$PASSTHROUGH_NAME" >/dev/null 2>&1 || true
  docker compose --env-file ports.env --env-file globalconfig.local.env --env-file infra.env up -d "$SERVICE"
  echo "Done -- '$SERVICE' is back on Docker."
  exit 0
fi

# The passthrough needs to join the same network the real stack is on. Read it off an
# always-up infra container instead of guessing the compose project name (which changes if
# COMPOSE_PROJECT_NAME is ever set).
NETWORK="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' kart-postgres 2>/dev/null || true)"
if [[ -z "$NETWORK" ]]; then
  echo "Can't find the compose network (is 'kart-postgres' running? run scripts/dev-up.sh first)." >&2
  exit 1
fi

if docker ps --format '{{.Names}}' | grep -qx "$PASSTHROUGH_NAME"; then
  echo "A passthrough for '$SERVICE' is already running. Run with --restore first if you want to change the port." >&2
  exit 1
fi

echo "Stopping '$SERVICE's Docker container..."
docker compose --env-file ports.env --env-file globalconfig.local.env --env-file infra.env stop "$SERVICE" >/dev/null 2>&1 || true
docker compose --env-file ports.env --env-file globalconfig.local.env --env-file infra.env rm -f "$SERVICE" >/dev/null 2>&1 || true

echo "Starting passthrough: Docker DNS name '$SERVICE' -> host.docker.internal:$LOCAL_PORT ..."
docker run -d --name "$PASSTHROUGH_NAME" \
  --network "$NETWORK" \
  --network-alias "$SERVICE" \
  --add-host host.docker.internal:host-gateway \
  alpine/socat \
  TCP-LISTEN:8080,fork,reuseaddr TCP:host.docker.internal:"$LOCAL_PORT" >/dev/null

cat <<EOF

Every other container still calls "http://$SERVICE:8080" unchanged -- it now reaches your
machine instead. Run kart-$SERVICE-service in Rider on http://localhost:$LOCAL_PORT (its
launchSettings.json applicationUrl already defaults to this) and debug as normal.

When done: scripts/debug-service.sh $SERVICE --restore
EOF
