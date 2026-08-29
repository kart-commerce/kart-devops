#!/usr/bin/env bash
# One-shot entry point: seeds the ENTIRE local-dev platform via real HTTP APIs --
#   1. Catalog: 50 categories, 500 products (862 SKUs), inventory, OpenSearch index
#      (scripts/catalog-seed.sh + scripts/catalog-seed-data-500.json -- already existed/was
#      generated for this purpose; not re-implemented here).
#   2. Everything else: customers, wishlists, carts, orders+payments (full saga), coupons/
#      promotions, and a few admin actions (scripts/platform-seed.py).
#
# Requires the stack to be up (scripts/dev-up.sh) and migrated (scripts/migrate-all.sh) first.
#
# Usage:
#   scripts/seed-everything.sh                  # catalog + platform, first-time seed
#   scripts/seed-everything.sh --skip-catalog   # just customers/orders/etc (catalog already seeded)
#   scripts/seed-everything.sh --skip-platform  # just the catalog half
#
# Re-run safety:
#   - Catalog step is NOT safe to re-run blind: category/product-service have no upsert-by-name
#     semantics (catalog-seed.sh's own header comment). Re-running without first clearing it
#     (scripts/catalog-clean.sh --yes) creates duplicate categories and 409s on already-existing
#     SKUs. This script checks whether categories already exist and skips straight to the
#     platform half with a warning instead of blindly re-seeding the catalog.
#   - Platform step (customers/orders/coupons/etc.) IS safe to re-run -- see platform-seed.py's
#     own header comment for exactly how (a per-run id keeps orders/coupons from colliding).
#
# Env overrides (see platform-seed.py for full list): SEED_CUSTOMER_COUNT, SEED_ORDER_COUNT.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/catalog-common.sh

SKIP_CATALOG=0
SKIP_PLATFORM=0
for a in "$@"; do
  case "$a" in
    --skip-catalog) SKIP_CATALOG=1 ;;
    --skip-platform) SKIP_PLATFORM=1 ;;
    *) echo "Unknown argument: $a" >&2; exit 2 ;;
  esac
done

echo "== Checking the stack is up (identity) =="
if ! curl -sf --max-time 5 "$IDENTITY_URL/.well-known/jwks.json" >/dev/null; then
  echo "kart-identity-service isn't reachable at $IDENTITY_URL -- run scripts/dev-up.sh first." >&2
  exit 1
fi

if [[ "$SKIP_CATALOG" -eq 0 ]]; then
  existing_categories="$(curl -sf --max-time 5 "$CATEGORY_URL/v1/categories" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "$existing_categories" -gt 0 ]]; then
    echo "== Catalog already has $existing_categories categories -- skipping catalog seed =="
    echo "   (run 'scripts/catalog-clean.sh --yes' first if you want a genuinely fresh catalog reseed)"
  else
    echo "== Step 1/2: seeding catalog (categories, 500 products, inventory, search index) =="
    scripts/catalog-seed.sh scripts/catalog-seed-data-500.json
  fi
else
  echo "== Step 1/2: skipped (--skip-catalog) =="
fi

if [[ "$SKIP_PLATFORM" -eq 0 ]]; then
  echo "== Step 2/2: seeding customers, wishlists, carts, orders, payments, offers, admin actions =="
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for scripts/platform-seed.py but wasn't found on PATH." >&2
    exit 1
  fi
  python3 scripts/platform-seed.py
else
  echo "== Step 2/2: skipped (--skip-platform) =="
fi

echo
echo "Done. Spot-check sync across stores with, e.g.:"
echo "  curl -s \$OPENSEARCH... /search-products-active/_count"
echo "  mongosh mongodb://localhost:\${MONGO_PORT}/kart_product --eval 'db.product_read_model.countDocuments({})'"
