#!/usr/bin/env bash
# Stops the full local platform stack. Pass -v to also wipe Postgres/Mongo/RabbitMQ/OpenSearch
# data volumes (fresh start next time, including re-running migrate-all.sh).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "${1:-}" == "-v" ]]; then
  docker compose --env-file ports.env down -v
else
  docker compose --env-file ports.env down
fi
