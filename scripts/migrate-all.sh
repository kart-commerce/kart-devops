#!/usr/bin/env bash
# Applies EF Core migrations for every Postgres-backed service against the shared `postgres`
# container docker-compose.yml starts (host-mapped to localhost:5433). None of these services
# auto-migrate on boot (kart-conventions.md's Database Migrations & Startup Readiness section:
# readiness must fail on a pending migration rather than silently applying one), so this is a
# required step after the first `docker compose up` and after pulling any migration change.
#
# Each service already owns a design-time DbContextFactory reading its own
# <SERVICE>_DB_CONNECTION_STRING env var (service-infra-rollout-checklist.md) -- this script just
# drives `dotnet ef database update` against each one directly from the host, since `postgres` is
# port-mapped to localhost:5433 anyway. No Dockerfile.migrate step needed even for the services
# that don't have one yet.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# infra.env holds the same postgres credentials docker-compose.yml bootstraps the shared
# container with (see infra.env.example) -- source it here instead of hardcoding
# Username=postgres;Password=postgres so this stays correct if those are ever changed.
set -a
source infra.env
set +a

ROOT="$(cd .. && pwd)"

# name | repo | database | env var
SERVICES=(
  "identity|kart-identity-service|kart_identity|IDENTITY_DB_CONNECTION_STRING"
  "user|kart-user-service|kart_user|USER_DB_CONNECTION_STRING"
  "product|kart-product-service|kart_product|PRODUCT_DB_CONNECTION_STRING"
  "category|kart-category-service|kart_category|CATEGORY_DB_CONNECTION_STRING"
  "inventory|kart-inventory-service|kart_inventory|INVENTORY_DB_CONNECTION_STRING"
  "cart|kart-cart-service|kart_cart|CART_DB_CONNECTION_STRING"
  "order|kart-order-service|kart_order|ORDER_DB_CONNECTION_STRING"
  "payment|kart-payment-service|kart_payment|PAYMENT_DB_CONNECTION_STRING"
  "offer|kart-offer-service|kart_offer|OFFER_DB_CONNECTION_STRING"
  "wishlist|kart-wishlist-service|kart_wishlist|WISHLIST_DB_CONNECTION_STRING"
  "notification|kart-notification-service|kart_notification|NOTIFICATION_DB_CONNECTION_STRING"
  "admin|kart-admin-service|kart_admin|ADMIN_DB_CONNECTION_STRING"
)

FAILED=()

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name repo db envvar <<< "$entry"
  repo_path="$ROOT/$repo"

  if [[ ! -d "$repo_path" ]]; then
    echo "skip $name: $repo not found at $repo_path"
    continue
  fi

  infra_csproj="$(find "$repo_path/src/Infrastructure" -maxdepth 1 -iname '*.csproj' | head -n1)"
  if [[ -z "$infra_csproj" ]]; then
    echo "skip $name: no Infrastructure .csproj found"
    continue
  fi

  echo "== migrating $name ($db) =="
  (
    cd "$repo_path"
    export "$envvar"="Host=localhost;Port=5433;Database=$db;Username=$POSTGRES_USER;Password=$POSTGRES_PASSWORD"
    dotnet tool restore >/dev/null
    dotnet ef database update --project "$infra_csproj" --startup-project "$infra_csproj"
  ) || FAILED+=("$name")
done

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "All migrations applied."
else
  echo "Migrations failed for: ${FAILED[*]}" >&2
  exit 1
fi
