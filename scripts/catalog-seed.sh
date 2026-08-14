#!/usr/bin/env bash
# Seeds a realistic catalog for local dev: 50 categories (10 departments x 4 subcategories) and
# 100 products (154 SKUs across all their variants) from catalog-seed-data.json, via the real
# HTTP APIs -- not raw SQL.
#
# Why the real APIs and not direct INSERTs: kart-product-service's `GET /v1/products/{sku}`
# (what kart-web's Product Detail Page calls) is served exclusively from MongoDB's
# `product_read_model`, which is populated only by product-service's own outbox-relay -> RabbitMQ
# -> catalog-projection-consumer pipeline after a *real* `POST /v1/product-groups` call. A raw SQL
# insert into `product_groups`/`variants` would sit in Postgres invisibly and never appear via
# that read path, and kart-search-service's OpenSearch index (what the Search page queries) would
# never learn about it either. Calling the real write APIs keeps Postgres, Mongo, and OpenSearch
# all correctly in sync, the same way kart-admin-web's real usage would.
#
# Auth: a client-credentials token (scope=admin) from kart-identity-service, using the
# `admin-service` client kart-identity-service's ServicePrincipalSeeder already provisions on
# every boot (same credential kart-admin-service itself uses server-to-server) -- see
# scripts/lib/catalog-common.sh. That one token's `roles=admin` + `scopes=admin` claims satisfy
# category-service's and inventory-service's AdminOnly policies and product-service's
# AdminOrPartner policy alike, so it's reused for every call below.
#
# Images: neither product-service's schema nor its API contract has an image field, so this
# script stashes a real per-SKU stock-photo URL (picsum.photos, deterministic by seed) in each
# variant's `attributes.extendedAttributes.imageUrl`/`images` -- forward-compatible metadata for
# whenever kart-web's PDP/search cards render a real photo instead of their current
# client-side-generated monogram placeholder (src/app/shared/util/placeholder-image.ts).
#
# Calls product-service/category-service/inventory-service directly (not through
# kart-admin-service's narrower `/admin/products` proxy, which has no brand/attributes/variant
# fields at all -- see the research this script was built from).
#
# Idempotency: category-service/product-service have no upsert-by-name semantics, so re-running
# this without `catalog-clean.sh --yes` first will create duplicates. Always clean first for a
# true fresh start.
#
# Usage: scripts/catalog-seed.sh [path/to/catalog-seed-data.json]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/catalog-common.sh

DATA_FILE="${1:-scripts/catalog-seed-data.json}"
if [[ ! -f "$DATA_FILE" ]]; then
  echo "Data file not found: $DATA_FILE" >&2
  exit 1
fi

echo "== Authenticating (client_credentials, scope=admin) =="
TOKEN="$(catalog::get_token)"

declare -A CATEGORY_ID
CATEGORY_FAILURES=0
PRODUCT_FAILURES=0
VARIANT_FAILURES=0
INVENTORY_FAILURES=0
CATEGORY_COUNT=0
PRODUCT_COUNT=0
VARIANT_COUNT=0
INVENTORY_COUNT=0
ALL_SKUS=()

catalog::image_url() {
  local sku="$1" idx="${2:-1}"
  echo "https://picsum.photos/seed/${sku}-${idx}/800/800"
}

echo "== Creating categories =="
while IFS=$'\t' read -r ref name parentRef; do
  parentId="null"
  if [[ -n "$parentRef" && "$parentRef" != "null" ]]; then
    parentId="${CATEGORY_ID[$parentRef]:-}"
    if [[ -z "$parentId" ]]; then
      echo "  skip category '$name' ($ref): parent '$parentRef' was never created" >&2
      CATEGORY_FAILURES=$((CATEGORY_FAILURES + 1))
      continue
    fi
    parentId="\"$parentId\""
  fi

  body="$(jq -nc --arg name "$name" --argjson parentId "$parentId" '{name: $name, parentId: $parentId}')"
  resp="$(catalog::request POST "$CATEGORY_URL/v1/categories" "$body")"
  catalog::split_response "$resp"

  if [[ "$CATALOG_STATUS" != 2* ]]; then
    echo "  FAILED: $name ($CATALOG_STATUS): $CATALOG_BODY" >&2
    CATEGORY_FAILURES=$((CATEGORY_FAILURES + 1))
    continue
  fi

  id="$(jq -r '.categoryId' <<<"$CATALOG_BODY")"
  CATEGORY_ID["$ref"]="$id"
  CATEGORY_COUNT=$((CATEGORY_COUNT + 1))
  echo "  created: $name -> $id"
done < <(jq -r '.categories[] | [.ref, .name, (.parentRef // "null")] | @tsv' "$DATA_FILE")

echo "== Creating products + variants =="
PRODUCT_COUNT_TOTAL="$(jq '.products | length' "$DATA_FILE")"
for i in $(seq 0 $((PRODUCT_COUNT_TOTAL - 1))); do
  product="$(jq -c ".products[$i]" "$DATA_FILE")"
  sku="$(jq -r '.sku' <<<"$product")"
  name="$(jq -r '.name' <<<"$product")"
  brand="$(jq -r '.brand' <<<"$product")"
  description="$(jq -r '.description' <<<"$product")"
  categoryRef="$(jq -r '.categoryRef' <<<"$product")"
  currency="$(jq -r '.currency' <<<"$product")"
  categoryId="${CATEGORY_ID[$categoryRef]:-}"

  if [[ -z "$categoryId" ]]; then
    echo "  skip product '$name': category '$categoryRef' was never created" >&2
    variantCount="$(jq '.variants | length' <<<"$product")"
    PRODUCT_FAILURES=$((PRODUCT_FAILURES + 1))
    VARIANT_FAILURES=$((VARIANT_FAILURES + variantCount))
    continue
  fi

  variantCount="$(jq '.variants | length' <<<"$product")"

  for v in $(seq 0 $((variantCount - 1))); do
    variant="$(jq -c ".variants[$v]" <<<"$product")"
    suffix="$(jq -r '.suffix' <<<"$variant")"
    price="$(jq -r '.price' <<<"$variant")"
    color="$(jq -r '.color // empty' <<<"$variant")"
    size="$(jq -r '.size // empty' <<<"$variant")"
    variantSku="${sku}-${suffix}"
    imageUrl="$(catalog::image_url "$variantSku" 1)"

    attributes="$(jq -nc \
      --arg color "$color" --arg size "$size" \
      '{
        size: (if $size == "" then null else $size end),
        color: (if $color == "" then null else $color end)
      }')"

    if [[ "$v" -eq 0 ]]; then
      body="$(jq -nc \
        --arg name "$name" --arg description "$description" --arg categoryId "$categoryId" \
        --arg brand "$brand" --arg sku "$variantSku" --argjson price "$price" --arg currency "$currency" \
        --argjson attributes "$attributes" --arg imageUrl "$imageUrl" \
        '{name: $name, description: $description, categoryId: $categoryId, brand: $brand, sku: $sku,
          price: {amount: $price, currency: $currency}, attributes: $attributes, imageUrl: $imageUrl}')"
      resp="$(catalog::request POST "$PRODUCT_URL/v1/product-groups" "$body")"
      catalog::split_response "$resp"

      if [[ "$CATALOG_STATUS" != 2* ]]; then
        echo "  FAILED product: $name ($variantSku) ($CATALOG_STATUS): $CATALOG_BODY" >&2
        PRODUCT_FAILURES=$((PRODUCT_FAILURES + 1))
        VARIANT_FAILURES=$((VARIANT_FAILURES + variantCount))
        break
      fi

      productGroupId="$(jq -r '.productGroupId' <<<"$CATALOG_BODY")"
      PRODUCT_COUNT=$((PRODUCT_COUNT + 1))
      VARIANT_COUNT=$((VARIANT_COUNT + 1))
      ALL_SKUS+=("$variantSku")
      echo "  created product: $name ($variantSku) -> group $productGroupId"
    else
      body="$(jq -nc \
        --arg sku "$variantSku" --argjson price "$price" --arg currency "$currency" \
        --argjson attributes "$attributes" \
        '{sku: $sku, price: {amount: $price, currency: $currency}, attributes: $attributes}')"
      resp="$(catalog::request POST "$PRODUCT_URL/v1/product-groups/$productGroupId/variants" "$body")"
      catalog::split_response "$resp"

      if [[ "$CATALOG_STATUS" != 2* ]]; then
        echo "  FAILED variant: $variantSku ($CATALOG_STATUS): $CATALOG_BODY" >&2
        VARIANT_FAILURES=$((VARIANT_FAILURES + 1))
        continue
      fi

      VARIANT_COUNT=$((VARIANT_COUNT + 1))
      ALL_SKUS+=("$variantSku")
      echo "    + variant: $variantSku"
    fi
  done
done

echo "== Provisioning inventory (kart-inventory-service) =="
# WH-1 gets full stock for every SKU; every 3rd SKU also gets a smaller WH-2 allocation, so the
# seeded catalog exercises both the single-warehouse and multi-warehouse availability paths.
idx=0
for sku in "${ALL_SKUS[@]}"; do
  qty=$(( (RANDOM % 150) + 30 ))
  threshold=$(( qty / 5 ))
  target=$(( qty + threshold ))
  body="$(jq -nc --arg sku "$sku" --argjson qty "$qty" --argjson threshold "$threshold" --argjson target "$target" \
    '{warehouseId: "WH-1", sku: $sku, initialQty: $qty, replenishmentThreshold: $threshold, targetStockingLevel: $target}')"
  resp="$(catalog::request POST "$INVENTORY_URL/v1/inventory/provision" "$body")"
  catalog::split_response "$resp"
  if [[ "$CATALOG_STATUS" != 2* ]]; then
    echo "  FAILED inventory WH-1: $sku ($CATALOG_STATUS): $CATALOG_BODY" >&2
    INVENTORY_FAILURES=$((INVENTORY_FAILURES + 1))
  else
    INVENTORY_COUNT=$((INVENTORY_COUNT + 1))
  fi

  if (( idx % 3 == 0 )); then
    qty2=$(( (RANDOM % 60) + 10 ))
    threshold2=$(( qty2 / 5 ))
    target2=$(( qty2 + threshold2 ))
    body2="$(jq -nc --arg sku "$sku" --argjson qty "$qty2" --argjson threshold "$threshold2" --argjson target "$target2" \
      '{warehouseId: "WH-2", sku: $sku, initialQty: $qty, replenishmentThreshold: $threshold, targetStockingLevel: $target}')"
    resp2="$(catalog::request POST "$INVENTORY_URL/v1/inventory/provision" "$body2")"
    catalog::split_response "$resp2"
    if [[ "$CATALOG_STATUS" != 2* ]]; then
      echo "  FAILED inventory WH-2: $sku ($CATALOG_STATUS): $CATALOG_BODY" >&2
      INVENTORY_FAILURES=$((INVENTORY_FAILURES + 1))
    else
      INVENTORY_COUNT=$((INVENTORY_COUNT + 1))
    fi
  fi
  idx=$((idx + 1))
done

echo "== Rebuilding kart-search-service's OpenSearch index =="
if curl -sS --max-time 120 -X POST "$SEARCH_URL/internal/reindex" | jq .; then
  :
else
  echo "warning: reindex call failed -- run it manually once kart-search-service is confirmed up." >&2
fi

echo "== Verifying a few SKUs are readable via GET /v1/products/{sku} =="
# product-service's outbox relay polls every 5s (OutboxRelayHostedService) before the
# ProductCreated event even reaches RabbitMQ, plus the catalog-projection consumer's own
# processing time on top -- poll instead of a fixed sleep.
VERIFY_SKUS=()
for sample_idx in 0 49 99; do
  s="$(jq -r ".products[$sample_idx].sku" "$DATA_FILE")"
  suffix="$(jq -r ".products[$sample_idx].variants[0].suffix" "$DATA_FILE")"
  VERIFY_SKUS+=("${s}-${suffix}")
done

for sku in "${VERIFY_SKUS[@]}"; do
  ok=""
  for _ in 1 2 3 4 5 6; do
    if curl -sf "$PRODUCT_URL/v1/products/$sku" >/dev/null; then
      ok="yes"
      break
    fi
    sleep 2
  done
  if [[ "$ok" == "yes" ]]; then
    echo "  OK: $sku is readable"
  else
    echo "  NOT YET VISIBLE: $sku (outbox/projection may still be catching up -- check manually)" >&2
  fi
done

echo
echo "== Summary =="
echo "Categories: $CATEGORY_COUNT created, $CATEGORY_FAILURES failed"
echo "Products:   $PRODUCT_COUNT created, $PRODUCT_FAILURES failed"
echo "Variants:   $VARIANT_COUNT created (incl. products' first variant), $VARIANT_FAILURES failed"
echo "Inventory:  $INVENTORY_COUNT rows created, $INVENTORY_FAILURES failed"

if [[ "$CATEGORY_FAILURES" -gt 0 || "$PRODUCT_FAILURES" -gt 0 || "$VARIANT_FAILURES" -gt 0 || "$INVENTORY_FAILURES" -gt 0 ]]; then
  exit 1
fi
