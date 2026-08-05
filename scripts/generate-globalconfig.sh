#!/usr/bin/env bash
# Generates compose/globalconfig/<service>.json for every app container in docker-compose.yml.
#
# Every kart-*-service calls Kart.Shared.Configuration's AddKartGlobalConfig() and refuses to
# boot unless GlobalConfig:Path resolves to a real file (see
# kart-shared/src/Kart.Shared.Configuration/GlobalConfigExtensions.cs) — and that file is layered
# in LAST, so any key it defines wins over a plain `environment:` entry of the same name. To avoid
# fighting that precedence, every secret/connection-string this stack needs lives in exactly one
# place: these generated files. docker-compose.yml's `environment:` blocks only ever set
# non-secret things (ASPNETCORE_ENVIRONMENT, GlobalConfig__Path itself).
#
# These are throwaway local-dev credentials for containers only reachable on your own Docker
# network — not real secrets. Re-run with --force to regenerate (e.g. after rotating the dev JWT
# keypair). Safe to gitignore (see ../.gitignore) since re-running this script reproduces them.

set -euo pipefail

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/compose/globalconfig"
FORCE="${1:-}"

mkdir -p "$OUT_DIR"

if [[ -f "$OUT_DIR/.generated" && "$FORCE" != "--force" ]]; then
  echo "compose/globalconfig/ already populated — skipping (pass --force to regenerate)."
  exit 0
fi

echo "Generating dev-only secrets into $OUT_DIR ..."

# --- One shared JWT RS256 keypair for kart-identity-service to mint/sign tokens with. ---
# Regenerated fresh here (never copied from any developer's real machine-local globalconfig.json,
# which is gitignored and machine-specific per PLATFORM_BLUEPRINT.md's Configuration Management
# section) — this keypair only ever signs tokens inside this compose network.
KEY_DIR="$(mktemp -d)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY_DIR/private.pem" 2>/dev/null
# Join the PEM's lines with literal \n escapes so it drops into a JSON string as one line.
PRIVATE_KEY_PEM_ESCAPED="$(sed ':a;N;$!ba;s/\n/\\n/g' "$KEY_DIR/private.pem")"
MFA_KEY_B64="$(openssl rand -base64 32)"
rm -rf "$KEY_DIR"

json() { printf '"%s"' "$1"; }

# identity — mints tokens (RS256 keypair + MFA encryption key), owns its own RabbitMQ user.
cat > "$OUT_DIR/identity.json" <<EOF
{
  "ConnectionStrings": {
    "IdentityDb": "Host=postgres;Port=5432;Database=kart_identity;Username=postgres;Password=postgres",
    "Redis": "redis:6379"
  },
  "Jwt": {
    "SigningKey": {
      "Kid": "identity-rs256-dev",
      "PrivateKeyPem": $(json "$PRIVATE_KEY_PEM_ESCAPED")
    }
  },
  "Mfa": { "Encryption": { "KeyBase64": "$MFA_KEY_B64" } },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" }
}
EOF

cat > "$OUT_DIR/user.json" <<'EOF'
{
  "ConnectionStrings": { "UserDb": "Host=postgres;Port=5432;Database=kart_user;Username=postgres;Password=postgres" },
  "Mongo": { "ConnectionString": "mongodb://mongo:27017" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Jwt": { "JwksUri": "http://identity:8080/.well-known/jwks.json" }
}
EOF

cat > "$OUT_DIR/product.json" <<'EOF'
{
  "ConnectionStrings": { "ProductDatabase": "Host=postgres;Port=5432;Database=kart_product;Username=postgres;Password=postgres" },
  "Mongo": { "ConnectionString": "mongodb://mongo:27017", "Database": "kart_product" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Jwt": { "Issuer": "kart-identity-service", "Audience": "kart-product-service", "SigningKey": "local-dev-signing-key-change-me-please-32chars-min" }
}
EOF

cat > "$OUT_DIR/category.json" <<'EOF'
{
  "ConnectionStrings": {
    "CategoryDatabase": "Host=postgres;Port=5432;Database=kart_category;Username=postgres;Password=postgres",
    "Redis": "redis:6379"
  },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Identity": { "JwksUri": "http://identity:8080/.well-known/jwks.json" }
}
EOF

cat > "$OUT_DIR/search.json" <<'EOF'
{
  "OpenSearch": { "Uri": "http://opensearch:9200" },
  "ProductCatalogSnapshot": { "ConnectionString": "Host=postgres;Port=5432;Database=kart_product;Username=postgres;Password=postgres" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" }
}
EOF

cat > "$OUT_DIR/inventory.json" <<'EOF'
{
  "ConnectionStrings": {
    "InventoryDatabase": "Host=postgres;Port=5432;Database=kart_inventory;Username=postgres;Password=postgres",
    "Redis": "redis:6379"
  },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Identity": { "JwksUri": "http://identity:8080/.well-known/jwks.json" }
}
EOF

cat > "$OUT_DIR/cart.json" <<'EOF'
{
  "ConnectionStrings": { "CartDb": "Host=postgres;Port=5432;Database=kart_cart;Username=postgres;Password=postgres" },
  "Mongo": { "ConnectionString": "mongodb://mongo:27017" },
  "Redis": { "ConnectionString": "redis:6379" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Grpc": { "InventoryServiceAddress": "http://inventory:8080" },
  "Jwt": { "Issuer": "kart-identity-service", "JwksUri": "http://identity:8080/.well-known/jwks.json" }
}
EOF

cat > "$OUT_DIR/order.json" <<'EOF'
{
  "ConnectionStrings": { "OrderDatabase": "Host=postgres;Port=5432;Database=kart_order;Username=postgres;Password=postgres" },
  "Mongo": { "ConnectionString": "mongodb://mongo:27017", "Database": "kart_order_read" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Inventory": { "BaseUrl": "http://inventory:8080" },
  "Payment": { "BaseUrl": "http://payment:8080" },
  "Identity": { "JwksUri": "http://identity:8080/.well-known/jwks.json" }
}
EOF

cat > "$OUT_DIR/payment.json" <<'EOF'
{
  "ConnectionStrings": { "PaymentDatabase": "Host=postgres;Port=5432;Database=kart_payment;Username=postgres;Password=postgres" },
  "Mongo": { "ConnectionString": "mongodb://mongo:27017", "Database": "kart_payment_read" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Gateway": { "SigningSecrets": { "simulated": "dev-simulated-gateway-signing-secret" } },
  "Identity": { "JwksUri": "http://identity:8080/.well-known/jwks.json" }
}
EOF

cat > "$OUT_DIR/offer.json" <<'EOF'
{
  "ConnectionStrings": { "OfferDatabase": "Host=postgres;Port=5432;Database=kart_offer;Username=postgres;Password=postgres" },
  "Mongo": { "ConnectionString": "mongodb://mongo:27017", "Database": "kart_offer_read" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Identity": { "JwksUri": "http://identity:8080/.well-known/jwks.json" }
}
EOF

cat > "$OUT_DIR/wishlist.json" <<'EOF'
{
  "ConnectionStrings": { "WishlistDb": "Host=postgres;Port=5432;Database=kart_wishlist;Username=postgres;Password=postgres" },
  "Mongo": { "ConnectionString": "mongodb://mongo:27017" },
  "Redis": { "ConnectionString": "redis:6379" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "ProductService": { "BaseUrl": "http://product:8080" },
  "Jwt": { "Issuer": "kart-identity-service", "JwksUri": "http://identity:8080/.well-known/jwks.json" }
}
EOF

cat > "$OUT_DIR/notification.json" <<'EOF'
{
  "ConnectionStrings": { "NotificationDb": "Host=postgres;Port=5432;Database=kart_notification;Username=postgres;Password=postgres" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" }
}
EOF

cat > "$OUT_DIR/delivery-tracking.json" <<'EOF'
{
  "Mongo": { "ConnectionString": "mongodb://mongo:27017" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Carriers": { "demo-carrier": { "WebhookSharedSecret": "dev-demo-carrier-webhook-secret" } }
}
EOF

# admin — Postgres-only (no Mongo/Redis, per its own database-design.md), plus its
# service-principal client-credentials secret for calling Identity's real lock/unlock routes
# and the five owning services' in-cluster base URLs it proxies write calls to.
cat > "$OUT_DIR/admin.json" <<'EOF'
{
  "ConnectionStrings": { "AdminDatabase": "Host=postgres;Port=5432;Database=kart_admin;Username=postgres;Password=postgres" },
  "RabbitMq": { "HostName": "rabbitmq", "UserName": "kart", "Password": "kart123" },
  "Identity": { "JwksUri": "http://identity:8080/.well-known/jwks.json" },
  "IdentityClientCredentials": { "ClientId": "admin-service", "ClientSecret": "dev-admin-service-client-secret", "Scope": "admin" },
  "DownstreamServices": {
    "Product": { "BaseUrl": "http://product:8080" },
    "Category": { "BaseUrl": "http://category:8080" },
    "Offer": { "BaseUrl": "http://offer:8080" },
    "Identity": { "BaseUrl": "http://identity:8080" },
    "Inventory": { "BaseUrl": "http://inventory:8080" }
  }
}
EOF

touch "$OUT_DIR/.generated"
echo "Done. Wrote $(ls "$OUT_DIR"/*.json | wc -l) globalconfig files to $OUT_DIR"
