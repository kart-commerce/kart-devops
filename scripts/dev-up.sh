#!/usr/bin/env bash
# Brings up the full local platform stack: 13 real backend services + kart-api-gateway +
# kart-web + kart-admin-web + shared Postgres/Mongo/Redis/RabbitMQ/OpenSearch.
#
# First run only: requires globalconfig.local.env to point GLOBALCONFIG_PATH at a real file (see
# the check below) and reminds you to run migrate-all.sh once Postgres is up.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# docker-compose.yml and docker-compose.observability.yml are separate Compose projects, each
# with its own default network by default -- so a container in one can't reach a container in
# the other by name (or even by IP; Compose's per-project bridges are mutually isolated).
# Both compose files declare their `default` network as this external, pre-existing one instead,
# so every container from both stacks ends up on the same bridge and otel-collector:4317
# resolves. Created here (idempotently -- `docker network create` on an existing name just
# errors harmlessly, hence `|| true`) rather than owned by either compose file, so it exists
# regardless of which stack comes up first, and regardless of SKIP_OBSERVABILITY_CHECK below
# skipping the observability stack entirely (the main stack's own `docker compose up` still
# needs this network to exist even when nothing is on the other side of it).
docker network create kart-shared-net >/dev/null 2>&1 || true

# Every backend service's Observability:Otlp:Endpoint points at the Collector unconditionally
# (see compose/globalconfig) -- if the observability stack isn't up yet, every service still
# boots fine (Kart.Shared.Observability treats a refused OTLP connection as a dropped export,
# never a startup failure), but silently ships zero logs/traces/metrics until someone notices.
# Catching that here, before the 22 real containers start, is cheap; catching it after because
# Grafana came up empty is not. Bypass with SKIP_OBSERVABILITY_CHECK=1 if you deliberately don't
# want the observability stack running (e.g. a low-memory machine).
if [[ "${SKIP_OBSERVABILITY_CHECK:-}" != "1" ]]; then
  echo "Verifying the observability stack (Grafana/Loki/Tempo/Prometheus/OTel Collector) is up and healthy..."
  if ! scripts/observability/up.sh --timeout 90; then
    echo >&2
    echo "Observability stack isn't healthy -- aborting before starting the main stack." >&2
    echo "Run scripts/observability/debug.sh for diagnostics, or SKIP_OBSERVABILITY_CHECK=1 $0 to bypass." >&2
    exit 1
  fi
  echo
fi

# ports.env is the single source of truth for every host port below -- see its own header
# comment and README.md's Ports table.
set -a
source ports.env
set +a

# globalconfig.local.env is gitignored and per-machine (see .gitignore's comment) -- it sets
# GLOBALCONFIG_PATH, which docker-compose.yml's `${GLOBALCONFIG_PATH}` volume entries mount at
# every container's /app/globalconfig.json. AddKartGlobalConfig(serviceName) refuses to let a
# service boot without that file, so fail fast here with an actionable message instead of
# letting every container crash-loop. Sourced with `set -a` for the same reason ports.env is --
# so GLOBALCONFIG_PATH is a real exported shell var, resolved by `docker compose` regardless of
# the separate `--env-file ports.env` flag below (shell env always wins over --env-file).
if [[ ! -f globalconfig.local.env ]]; then
  echo "globalconfig.local.env is missing -- copy globalconfig.local.env.example to" >&2
  echo "globalconfig.local.env and point GLOBALCONFIG_PATH at your real GlobalConfig JSON file" >&2
  echo "(compose/globalconfig/global.json.example documents the shape it needs)." >&2
  exit 1
fi
set -a
source globalconfig.local.env
set +a
if [[ -z "${GLOBALCONFIG_PATH:-}" || ! -f "$GLOBALCONFIG_PATH" ]]; then
  echo "GLOBALCONFIG_PATH ('${GLOBALCONFIG_PATH:-}') in globalconfig.local.env isn't set or" >&2
  echo "doesn't point at a real file -- fix it there before continuing." >&2
  exit 1
fi

# infra.env is gitignored and holds the shared postgres/rabbitmq containers' own bootstrap
# credentials (see infra.env.example) -- kept out of docker-compose.yml itself so no credential
# is written in plain text into a committed file. Unlike globalconfig.local.env's per-machine
# path, these have a sensible throwaway default, so auto-copy the example instead of failing.
if [[ ! -f infra.env ]]; then
  echo "infra.env is missing -- creating it from infra.env.example (default dev-only creds)."
  cp infra.env.example infra.env
fi
set -a
source infra.env
set +a

# kart-commerce/ (the parent of every kart-*-service repo) isn't itself a git repo, so this
# can't be committed anywhere -- several services build with that directory as their Docker
# context (cross-repo ProjectReference to kart-shared) and Docker only reads a .dockerignore at
# the context root. Without it, each developer's own stale host obj/bin output gets copied into
# the build and corrupts the restore state (see docker-compose.yml's comment / README).
PARENT_DOCKERIGNORE="../.dockerignore"
if [[ ! -f "$PARENT_DOCKERIGNORE" ]]; then
  echo "Creating $PARENT_DOCKERIGNORE (required for cross-repo builds -- see README)..."
  cat > "$PARENT_DOCKERIGNORE" <<'EOF'
**/bin/
**/obj/
**/TestResults/
**/.git/
**/.github/
**/.vs/
**/.vscode/
**/.idea/
**/*.user
**/appsettings.Local.json
EOF
fi

# Every service's Serilog file sink (kart-shared's ObservabilityExtensions.AddKartObservability)
# writes into a bind-mounted host directory (docker-compose.yml's kart-internals/logs/<service>
# volumes) as whichever user that service's container happens to run as -- some Dockerfiles drop
# to a non-root UID, some don't, and that can change independently of this script. If Docker has
# to auto-create one of these directories on first `up` it does so as root:root 0755, which a
# non-root container user can't write into -- and Serilog swallows sink write failures silently
# by default, so the log file just never appears with no error anywhere. Pre-creating every log
# dir here (before Docker ever touches it) and keeping it world-writable sidesteps the UID
# question entirely, so this can't regress no matter which user a given service's container ends
# up running as.
LOG_SERVICES=(identity category user product search inventory cart order payment offer wishlist notification delivery-tracking admin)
for svc in "${LOG_SERVICES[@]}"; do
  dir="../kart-internals/logs/$svc"
  mkdir -p "$dir"
  if ! chmod 777 "$dir" 2>/dev/null; then
    echo "Warning: couldn't chmod $dir writable (likely root-owned from an old run) --" >&2
    echo "that service's logs may silently fail to write. Fix once with: sudo chmod -R 777 $dir" >&2
  fi
done

echo "Building and starting the stack (this can take a while the first time)..."
docker compose --env-file ports.env --env-file globalconfig.local.env --env-file infra.env up --build -d

cat <<EOF

Stack starting. Useful next steps:
  scripts/dev-logs.sh                 tail every service's logs together
  scripts/dev-logs.sh gateway         tail just one service
  docker compose ps                   see container status
  scripts/migrate-all.sh              apply EF Core migrations (run once Postgres is healthy,
                                       and again any time a service adds a new migration)

Once migrated:
  Gateway (what the FE talks to):     http://localhost:${GATEWAY_PORT}
  kart-web (storefront):              http://localhost:${WEB_PORT}
  kart-admin-web (back office):       http://localhost:${ADMIN_WEB_PORT}
  RabbitMQ management UI:             http://localhost:${RABBITMQ_UI_PORT}  (${RABBITMQ_DEFAULT_USER} / ${RABBITMQ_DEFAULT_PASS})

scripts/dev-down.sh stops everything. See README.md for the full port table and how this
relates to kart-infra's kind/Helm cluster.
EOF
