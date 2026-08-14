#!/usr/bin/env bash
# Wipes every catalog-management table/collection/index for a fresh local-dev start:
# kart_category + kart_product + kart_inventory Postgres tables, kart-product-service's Mongo
# `product_read_model` read side, and rebuilds kart-search-service's OpenSearch index (empty).
#
# Truncates directly against Postgres/Mongo rather than going through each service's own delete
# API (none of category/product/inventory-service expose a bulk-delete endpoint at all -- this
# is genuinely the only way to clear them short of dropping and re-migrating each database).
# Safe to run whether or not the backend services are up, EXCEPT the final reindex step, which
# needs kart-search-service reachable.
#
# Destructive. Requires --yes to actually run; otherwise prints what it would do and exits 1.
#
# Usage: scripts/catalog-clean.sh --yes

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/catalog-common.sh

if [[ "${1:-}" != "--yes" ]]; then
  cat >&2 <<EOF
This will TRUNCATE every catalog table below, empty MongoDB's product_read_model collection,
and rebuild kart-search-service's OpenSearch index empty:

  kart_category:  categories, category_outbox_events, attributes, attribute_values,
                  attribute_outbox_events
  kart_product:   product_groups, variants, product_outbox_events
  kart_inventory: warehouse_stock, reservations, reservation_allocations,
                  inventory_outbox_events

This also permanently removes kart-inventory-service's migration-seeded DEMO-SKU-1 demo rows --
they are NOT restored by re-running this script or migrate-all.sh (EF Core's HasData seed is
only ever applied once, at migration time, against a fresh database).

Re-run with --yes to proceed:
  scripts/catalog-clean.sh --yes
EOF
  exit 1
fi

echo "== Truncating kart_category =="
catalog::psql kart_category -c \
  "TRUNCATE TABLE categories, category_outbox_events, attributes, attribute_values, attribute_outbox_events RESTART IDENTITY CASCADE;"

echo "== Truncating kart_product =="
catalog::psql kart_product -c \
  "TRUNCATE TABLE product_groups, variants, product_outbox_events RESTART IDENTITY CASCADE;"

echo "== Truncating kart_inventory =="
catalog::psql kart_inventory -c \
  "TRUNCATE TABLE warehouse_stock, reservations, reservation_allocations, inventory_outbox_events RESTART IDENTITY CASCADE;"

echo "== Emptying MongoDB product_read_model =="
catalog::mongo --eval 'db.product_read_model.deleteMany({})'

echo "== Rebuilding kart-search-service's OpenSearch index (now empty) =="
if curl -sf -X POST "$SEARCH_URL/internal/reindex" | jq .; then
  :
else
  echo "warning: reindex call to $SEARCH_URL/internal/reindex failed -- is kart-search-service running? Run it manually once the service is up." >&2
fi

echo "Catalog data cleaned."
