#!/usr/bin/env bash
# Stops the observability stack. Pass -v to also wipe its data volumes (Loki chunks, Tempo
# blocks, Prometheus TSDB, Grafana's own sqlite db) -- fresh start next time, matching
# dev-down.sh's -v convention for the main stack.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/observability/lib/common.sh

if [[ "${1:-}" == "-v" ]]; then
  echo "Stopping the observability stack and wiping its data volumes..."
  obs::compose down -v
else
  echo "Stopping the observability stack (data volumes kept -- pass -v to wipe them)..."
  obs::compose down
fi
