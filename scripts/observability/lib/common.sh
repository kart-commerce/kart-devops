#!/usr/bin/env bash
# Shared helpers for scripts/observability/*.sh -- container names, health-check URLs, and the
# poll/print logic every one of those scripts (and dev-up.sh's pre-flight check) needs.
# Sourced, not executed directly (no shebang execution expected).

DEVOPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OBS_COMPOSE_FILE="$DEVOPS_ROOT/docker-compose.observability.yml"

# docker-compose.observability.yml hardcodes every port directly (no ports.env interpolation --
# see its own header comment: this stack is intentionally standalone/copy-paste-free, not tied
# to the main stack's port registry). Mirrored here 1:1 -- keep both in sync if either changes.
OBS_GRAFANA_PORT=3000
OBS_LOKI_PORT=3100
OBS_TEMPO_PORT=3200
OBS_PROMETHEUS_PORT=9090
OBS_OTLP_GRPC_PORT=4317
OBS_OTLP_HTTP_PORT=4318
OBS_OTEL_METRICS_PORT=8889
OBS_OTEL_HEALTH_PORT=13133

# Ordered so up.sh/status.sh print dependency-first (backends before the thing that queries
# them) -- matches docker-compose.observability.yml's own depends_on ordering.
OBS_CONTAINERS=(observability-loki observability-tempo observability-prometheus observability-otel-collector observability-grafana)

# name -> health-check URL. A 200 response is the only thing checked (obs::http_ok below) --
# none of these need body inspection for a basic up/down signal.
declare -A OBS_HEALTH_URLS=(
  [observability-loki]="http://localhost:${OBS_LOKI_PORT}/ready"
  [observability-tempo]="http://localhost:${OBS_TEMPO_PORT}/ready"
  [observability-prometheus]="http://localhost:${OBS_PROMETHEUS_PORT}/-/healthy"
  [observability-otel-collector]="http://localhost:${OBS_OTEL_HEALTH_PORT}/"
  [observability-grafana]="http://localhost:${OBS_GRAFANA_PORT}/api/health"
)

declare -A OBS_LABELS=(
  [observability-loki]="Loki"
  [observability-tempo]="Tempo"
  [observability-prometheus]="Prometheus"
  [observability-otel-collector]="OTel Collector"
  [observability-grafana]="Grafana"
)

obs::compose() {
  docker compose -f "$OBS_COMPOSE_FILE" "$@"
}

# 0 if the container exists and Docker reports it running; 1 otherwise. Distinct from
# obs::http_ok -- a container can be "running" while its app inside is still booting (Tempo/Loki
# ring formation, Grafana provisioning, etc.), which is exactly what obs::http_ok is for.
obs::container_running() {
  local name="$1"
  [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

obs::http_ok() {
  local url="$1"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)"
  [[ "$code" == "200" ]]
}

# Prints one line per container: name, Docker running state, HTTP health state. Used by
# status.sh directly and by up.sh/dev-up.sh after polling.
obs::print_status() {
  local name running health
  printf '%-28s %-10s %-10s\n' "COMPONENT" "CONTAINER" "HEALTH"
  for name in "${OBS_CONTAINERS[@]}"; do
    if obs::container_running "$name"; then running="up"; else running="down"; fi
    if [[ "$running" == "up" ]] && obs::http_ok "${OBS_HEALTH_URLS[$name]}"; then
      health="healthy"
    elif [[ "$running" == "up" ]]; then
      health="starting"
    else
      health="-"
    fi
    printf '%-28s %-10s %-10s\n' "${OBS_LABELS[$name]}" "$running" "$health"
  done
}

# Polls every container until all report healthy or $1 seconds elapse. Echoes progress dots to
# stderr so it's visible under `set -x`-free scripts without polluting stdout. Returns 1 on
# timeout -- callers (up.sh, dev-up.sh) decide whether that's fatal.
obs::wait_all_healthy() {
  local timeout="${1:-60}"
  local waited=0
  local name all_healthy

  while (( waited < timeout )); do
    all_healthy=true
    for name in "${OBS_CONTAINERS[@]}"; do
      if ! { obs::container_running "$name" && obs::http_ok "${OBS_HEALTH_URLS[$name]}"; }; then
        all_healthy=false
        break
      fi
    done
    if $all_healthy; then
      return 0
    fi
    printf '.' >&2
    sleep 2
    waited=$(( waited + 2 ))
  done
  echo >&2
  return 1
}
