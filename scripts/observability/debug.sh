#!/usr/bin/env bash
# Diagnostics for when the observability stack isn't behaving -- one place to look instead of
# manually cross-referencing `docker compose ps`, container logs, and Grafana's datasource
# health API. Read-only: never restarts/recreates anything (use up.sh/restart.sh for that).
#
# Usage:
#   scripts/observability/debug.sh              # full report
#   scripts/observability/debug.sh --logs-only  # skip the container/port checks, just dump
#                                                # each unhealthy component's recent logs

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/observability/lib/common.sh

LOGS_ONLY=false
[[ "${1:-}" == "--logs-only" ]] && LOGS_ONLY=true

section() { echo; echo "=== $1 ==="; }

if ! $LOGS_ONLY; then
  section "Container status"
  obs::compose ps

  section "Health check summary"
  obs::print_status

  section "Host port availability"
  # A container stuck "Restarting" or failing to bind is often just another process already on
  # the port (a second `docker compose up` from a different checkout, a leftover host process,
  # etc.) -- check that before assuming the stack itself is broken.
  for portvar in OBS_GRAFANA_PORT:Grafana OBS_LOKI_PORT:Loki OBS_TEMPO_PORT:Tempo OBS_PROMETHEUS_PORT:Prometheus OBS_OTLP_GRPC_PORT:"OTLP gRPC" OBS_OTLP_HTTP_PORT:"OTLP HTTP" OBS_OTEL_METRICS_PORT:"Collector metrics" OBS_OTEL_HEALTH_PORT:"Collector health"; do
    var="${portvar%%:*}"; label="${portvar#*:}"
    port="${!var}"
    holder="$(docker ps --filter "publish=${port}" --format '{{.Names}}' | head -1)"
    if [[ -n "$holder" ]]; then
      echo "${port} (${label}): held by container '${holder}'"
    elif command -v ss >/dev/null && ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q ":${port}"; then
      echo "${port} (${label}): held by a NON-Docker process on this host -- that's likely why the container won't bind"
    else
      echo "${port} (${label}): free (nothing is listening -- the container for it is probably down)"
    fi
  done

  section "Known failure mode: Tempo OTLP receiver config"
  # Historical bug (see observability/tempo.yaml's own comment): an empty `grpc:`/`http:` block
  # under distributor.receivers.otlp.protocols silently never starts the OTLP listener, and the
  # Collector's otlp/tempo exporter then spins forever on "connection refused" -- Tempo's own
  # startup log only shows its internal 3200/9095 ports in that case, never 4317/4318.
  if grep -A1 "^\s*grpc:\s*$" observability/tempo.yaml | grep -q "endpoint:"; then
    echo "tempo.yaml's otlp grpc receiver has an explicit endpoint -- OK."
  else
    echo "tempo.yaml's otlp grpc receiver may be missing an explicit 'endpoint:' -- check observability/tempo.yaml" >&2
  fi

  section "Grafana -> datasource connectivity (as Grafana itself sees it)"
  if obs::http_ok "http://localhost:${OBS_GRAFANA_PORT}/api/health"; then
    for uid in prometheus loki tempo; do
      resp="$(curl -sS -u admin:admin --max-time 5 "http://localhost:${OBS_GRAFANA_PORT}/api/datasources/uid/${uid}/health" 2>/dev/null || echo '{"status":"unreachable"}')"
      status="$(echo "$resp" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")"
      echo "${uid}: ${status}"
      [[ "$status" != "OK" ]] && echo "  $resp"
    done
  else
    echo "Grafana isn't healthy yet -- skipping datasource checks (nothing to query through)."
  fi
fi

section "Recent logs (last 40 lines) per component"
for name in "${OBS_CONTAINERS[@]}"; do
  if $LOGS_ONLY && obs::container_running "$name" && obs::http_ok "${OBS_HEALTH_URLS[$name]}"; then
    continue # --logs-only: skip components that are already healthy
  fi
  echo
  echo "--- ${OBS_LABELS[$name]} (${name}) ---"
  docker logs "$name" --tail 40 2>&1 || echo "(container not found -- is the stack up? scripts/observability/up.sh)"
done
