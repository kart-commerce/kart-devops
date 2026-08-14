#!/usr/bin/env bash
# One-shot health snapshot of the observability stack -- no waiting/polling, just prints what's
# true right now. Exits 1 if any component isn't healthy, so it's usable as a plain gate in
# other scripts (e.g. `scripts/observability/status.sh || scripts/observability/up.sh`).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/observability/lib/common.sh

obs::print_status

all_healthy=true
for name in "${OBS_CONTAINERS[@]}"; do
  if ! { obs::container_running "$name" && obs::http_ok "${OBS_HEALTH_URLS[$name]}"; }; then
    all_healthy=false
  fi
done

$all_healthy || exit 1
