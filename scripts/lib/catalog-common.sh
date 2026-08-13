#!/usr/bin/env bash
# Shared helpers for catalog-clean.sh / catalog-seed.sh -- local-dev catalog reset+seed tooling
# spanning kart-category-service, kart-product-service, kart-inventory-service and
# kart-search-service. Sourced, not executed directly (no shebang execution expected).

DEVOPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

set -a
source "$DEVOPS_ROOT/ports.env"
source "$DEVOPS_ROOT/infra.env"
set +a

IDENTITY_URL="http://localhost:${IDENTITY_PORT}"
CATEGORY_URL="http://localhost:${CATEGORY_PORT}"
PRODUCT_URL="http://localhost:${PRODUCT_PORT}"
INVENTORY_URL="http://localhost:${INVENTORY_PORT}"
SEARCH_URL="http://localhost:${SEARCH_PORT}"

# kart-identity-service's ServicePrincipalSeeder (compose/globalconfig/global.json's
# ServicePrincipalSeeds) provisions this client_id/secret pair with Role=Admin on every boot --
# the same credential kart-admin-service itself uses server-to-server. Dev-only, not a secret
# worth guarding; override via env if a given machine's globalconfig.local.env diverges.
CATALOG_CLIENT_ID="${CATALOG_CLIENT_ID:-admin-service}"
CATALOG_CLIENT_SECRET="${CATALOG_CLIENT_SECRET:-dev-admin-service-client-secret}"

# Prints a bearer token (scope=admin) on stdout. This scope satisfies category/product/
# inventory-service's AdminOnly / AdminOrPartner policies alike (see catalog-seed.sh's header
# comment for why one token works across all three).
catalog::get_token() {
  local response
  response="$(curl -sf -X POST "$IDENTITY_URL/v1/auth/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_id=${CATALOG_CLIENT_ID}" \
    --data-urlencode "client_secret=${CATALOG_CLIENT_SECRET}" \
    --data-urlencode 'scope=admin')" || {
    echo "catalog::get_token: could not reach ${IDENTITY_URL}/v1/auth/token -- is kart-identity-service running (scripts/dev-up.sh)?" >&2
    return 1
  }
  local token
  token="$(jq -r '.accessToken // empty' <<<"$response")"
  if [[ -z "$token" ]]; then
    echo "catalog::get_token: no accessToken in response: $response" >&2
    return 1
  fi
  echo "$token"
}

catalog::psql() {
  local db="$1"; shift
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$db" -v ON_ERROR_STOP=1 "$@"
}

catalog::mongo() {
  mongosh --quiet "mongodb://localhost:${MONGO_PORT}/kart_product" "$@"
}

# Authenticated JSON request. Expects $TOKEN to already be set (catalog::get_token). Prints the
# response body on stdout and the HTTP status on the line after it -- callers split on the last
# newline (see catalog-seed.sh) rather than parsing curl's own -w output inline, so a
# multi-line/pretty-printed JSON error body doesn't get mangled.
catalog::request() {
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS --max-time 30 -X "$method" "$url" \
      -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
      -d "$body" -w $'\n%{http_code}'
  else
    curl -sS --max-time 30 -X "$method" "$url" \
      -H "Authorization: Bearer ${TOKEN}" -w $'\n%{http_code}'
  fi
}

# Splits a catalog::request response into body + status. Usage:
#   resp="$(catalog::request POST "$url" "$body")"
#   catalog::split_response "$resp"; echo "$CATALOG_STATUS $CATALOG_BODY"
catalog::split_response() {
  local resp="$1"
  CATALOG_STATUS="${resp##*$'\n'}"
  CATALOG_BODY="${resp%$'\n'*}"
}
