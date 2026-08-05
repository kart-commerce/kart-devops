#!/usr/bin/env bash
# Brings up the full local platform stack: 13 real backend services + kart-api-gateway +
# kart-web + kart-admin-web + shared Postgres/Mongo/Redis/RabbitMQ/OpenSearch.
#
# First run only: generates compose/globalconfig/ (throwaway local secrets, gitignored) and
# reminds you to run migrate-all.sh once Postgres is up.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

./scripts/generate-globalconfig.sh

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

echo "Building and starting the stack (this can take a while the first time)..."
docker compose up --build -d

cat <<'EOF'

Stack starting. Useful next steps:
  scripts/dev-logs.sh                 tail every service's logs together
  scripts/dev-logs.sh gateway         tail just one service
  docker compose ps                   see container status
  scripts/migrate-all.sh              apply EF Core migrations (run once Postgres is healthy,
                                       and again any time a service adds a new migration)

Once migrated:
  Gateway (what the FE talks to):     http://localhost:8100
  kart-web (storefront):              http://localhost:4210
  kart-admin-web (back office):       http://localhost:4300
  RabbitMQ management UI:             http://localhost:15672  (kart / kart123)

scripts/dev-down.sh stops everything. See README.md for the full port table and how this
relates to kart-infra's kind/Helm cluster.
EOF
