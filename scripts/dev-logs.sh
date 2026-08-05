#!/usr/bin/env bash
# Tails logs for the whole stack, or a single service if named (e.g. dev-logs.sh gateway).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker compose logs -f --tail=200 "$@"
