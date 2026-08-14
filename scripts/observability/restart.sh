#!/usr/bin/env bash
# Restarts the observability stack. Default is a fast in-place `docker compose restart`
# (containers recreated in place, volumes/images untouched -- use this after editing one of
# observability/*.yaml's configs, since those are read on container start, not live-reloaded).
# Pass --recreate for a full down+up instead (e.g. after changing
# docker-compose.observability.yml itself, which a plain `restart` won't pick up).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/observability/lib/common.sh

if [[ "${1:-}" == "--recreate" ]]; then
  echo "Recreating the observability stack (down + up)..."
  obs::compose down
  exec scripts/observability/up.sh
fi

echo "Restarting the observability stack in place..."
obs::compose restart

echo -n "Waiting for every component to report healthy (up to 60s)"
if obs::wait_all_healthy 60; then
  echo "All components healthy."
  echo
  obs::print_status
else
  echo "Timed out waiting for all components to become healthy after restart." >&2
  obs::print_status >&2
  echo "Run scripts/observability/debug.sh for diagnostics." >&2
  exit 1
fi
