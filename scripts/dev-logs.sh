#!/usr/bin/env bash
# Tails logs for the whole stack, or a single service if named (e.g. dev-logs.sh gateway).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker compose --env-file ports.env --env-file globalconfig.local.env --env-file infra.env logs -f --tail=200 "$@"
