#!/usr/bin/env bash
# Puts enough data behind the storefront that a recruiter/CTO clicking the live link sees a real
# catalog, not an empty page. Run once, from kart-devops/, AFTER migrate-all.sh has succeeded
# (these seeders write through EF Core / the same schema the services own — an empty schema
# makes them fail, not just look empty).
#
# Each seeder's actual options (batch size, --seed for reproducibility, etc.) are documented in
# its own script — this just wires them together with reasonable demo-sized counts. Adjust the
# counts freely; a few hundred products reads better in a demo than 100k.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."   # -> kart-devops/
ROOT="$(cd .. && pwd)"
set -a; source infra.env; set +a

echo "==> Seeding categories"
(cd "$ROOT/kart-category-service" && \
  CATEGORY_DB_CONNECTION_STRING="Host=localhost;Port=5433;Database=kart_category;Username=postgres;Password=${POSTGRES_PASSWORD}" \
  ./scripts/seed-categories.sh 200)

echo "==> Seeding sample orders (exercises the order/payment/inventory read paths in demo)"
(cd "$ROOT/kart-order-service" && \
  ORDER_DB_CONNECTION_STRING="Host=localhost;Port=5433;Database=kart_order;Username=postgres;Password=${POSTGRES_PASSWORD}" \
  ./scripts/seed-orders.sh 50)

echo
echo "No dedicated seed script exists yet for products/inventory/offers as of this writing —"
echo "check each service's own scripts/ and README.md for the current story before relying on"
echo "this list being complete; add calls here once one exists rather than seeding by hand every"
echo "time you redeploy."
