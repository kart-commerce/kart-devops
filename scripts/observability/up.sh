#!/usr/bin/env bash
# Starts the shared local-dev observability stack (Grafana + Loki + Tempo + Prometheus + an
# OpenTelemetry Collector -- see ../../docker-compose.observability.yml's own header) and waits
# for every component to report healthy before returning. Safe to re-run -- `docker compose up
# -d` is idempotent, so this is also how dev-up.sh's pre-flight check brings the stack up if it
# isn't already running.
#
# Usage:
#   scripts/observability/up.sh              # start + wait up to 60s for health
#   scripts/observability/up.sh --timeout 90 # wait longer (slow machine / cold image pulls)
#   scripts/observability/up.sh --no-wait    # start and return immediately, no health polling

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/observability/lib/common.sh

TIMEOUT=60
WAIT=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --no-wait) WAIT=false; shift ;;
    *) echo "Usage: $0 [--timeout SECONDS] [--no-wait]" >&2; exit 1 ;;
  esac
done

echo "Starting the observability stack (Grafana/Loki/Tempo/Prometheus/OTel Collector)..."
obs::compose up -d

if ! $WAIT; then
  echo "Started (not waiting for health -- pass no flag, or run scripts/observability/status.sh, to check)."
  exit 0
fi

echo -n "Waiting for every component to report healthy (up to ${TIMEOUT}s)"
if obs::wait_all_healthy "$TIMEOUT"; then
  echo "All components healthy."
  echo
  obs::print_status
  cat <<EOF

Grafana:        http://localhost:${OBS_GRAFANA_PORT} (admin/admin)
Loki:           http://localhost:${OBS_LOKI_PORT}
Tempo:          http://localhost:${OBS_TEMPO_PORT}
Prometheus:     http://localhost:${OBS_PROMETHEUS_PORT}
OTLP ingest:    http://localhost:${OBS_OTLP_GRPC_PORT} (gRPC) / http://localhost:${OBS_OTLP_HTTP_PORT} (HTTP)

Point a service's Observability:Otlp:Endpoint at the OTLP ingest address above -- never at
Loki/Tempo/Prometheus directly (see observability/README.md).
EOF
else
  echo "Timed out after ${TIMEOUT}s waiting for all components to become healthy." >&2
  echo >&2
  obs::print_status >&2
  echo >&2
  echo "Run scripts/observability/debug.sh for diagnostics (recent logs per component, common failure modes)." >&2
  exit 1
fi
