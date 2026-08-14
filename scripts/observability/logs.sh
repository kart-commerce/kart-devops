#!/usr/bin/env bash
# Tails logs for the observability stack, or a single component if named -- mirrors
# ../dev-logs.sh's pattern for the main stack.
#
# Usage:
#   scripts/observability/logs.sh                 # every component
#   scripts/observability/logs.sh otel-collector   # just the collector (also: loki, tempo,
#                                                   # prometheus, grafana)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/observability/lib/common.sh

obs::compose logs -f --tail=200 "$@"
