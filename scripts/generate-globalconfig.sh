#!/usr/bin/env bash
# Generates ONE shared compose/globalconfig/global.json every app container in
# docker-compose.yml mounts at /app/globalconfig.json.
#
# Every kart-*-service calls Kart.Shared.Configuration's AddKartGlobalConfig(serviceName) and
# refuses to boot unless GlobalConfig:Path resolves to a real file (see
# kart-shared/src/Kart.Shared.Configuration/GlobalConfigExtensions.cs) — and that file is layered
# in LAST, so any key it defines wins over a plain `environment:` entry of the same name. To avoid
# fighting that precedence, every secret/connection-string this stack needs lives in exactly one
# place: this generated file's "Global" section (platform-wide defaults every service inherits —
# RabbitMQ broker location, the log directory root) plus its "Services:<name>" section (each
# service's own secrets). docker-compose.yml's `environment:` blocks only ever set non-secret
# things (ASPNETCORE_ENVIRONMENT, GlobalConfig__Path itself).
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

echo "Generating dev-only secrets into $OUT_DIR/global.json ..."

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

# Every service's log directory is {Global:LogRoot}/{serviceName} (serviceName is the full
# "kart-<name>-service" string, computed by Kart.Shared.Configuration) — matching
# docker-compose.yml's per-service ./compose/globalconfig/logs/<name>:/var/log/kart/kart-<name>-service
# mount, so `tail`-ing a log file on the host reaches the exact file the container's Serilog file
# sink writes. The mount's destination must use the full service name, not the abbreviated <name>
# used on the host side below — a prior version of this mount used <name> on both sides, which
# silently wrote every service's logs into an unmounted container path instead.
cat > "$OUT_DIR/global.json" <<EOF
{
  "Global": {
    "LogRoot": "/var/log/kart",
    "RabbitMq": { "HostName": "rabbitmq", "Port": 5672, "UserName": "kart", "Password": "kart123" },
    "Identity": { "JwksUri": "http://identity:8080/.well-known/jwks.json" }
  },
  "Services": {
    "kart-identity-service": {
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
      "ServicePrincipalSeeds": [
        { "ClientId": "admin-service", "ClientSecret": "dev-admin-service-client-secret", "Role": "Admin" }
      ]
    },
    "kart-user-service": {
      "ConnectionStrings": { "UserDb": "Host=postgres;Port=5432;Database=kart_user;Username=postgres;Password=postgres" },
      "Mongo": { "ConnectionString": "mongodb://mongo:27017" },
      "Jwt": { "JwksUri": "http://identity:8080/.well-known/jwks.json" }
    },
    "kart-product-service": {
      "ConnectionStrings": {
        "ProductDatabase": "Host=postgres;Port=5432;Database=kart_product;Username=postgres;Password=postgres",
        "Redis": "redis:6379"
      },
      "Mongo": { "ConnectionString": "mongodb://mongo:27017", "Database": "kart_product" }
    },
    "kart-category-service": {
      "ConnectionStrings": {
        "CategoryDatabase": "Host=postgres;Port=5432;Database=kart_category;Username=postgres;Password=postgres",
        "Redis": "redis:6379"
      }
    },
    "kart-search-service": {
      "OpenSearch": { "Uri": "http://opensearch:9200" },
      "ProductCatalogSnapshot": { "ConnectionString": "Host=postgres;Port=5432;Database=kart_product;Username=postgres;Password=postgres" }
    },
    "kart-inventory-service": {
      "ConnectionStrings": {
        "InventoryDatabase": "Host=postgres;Port=5432;Database=kart_inventory;Username=postgres;Password=postgres",
        "Redis": "redis:6379"
      }
    },
    "kart-cart-service": {
      "ConnectionStrings": { "CartDb": "Host=postgres;Port=5432;Database=kart_cart;Username=postgres;Password=postgres" },
      "Mongo": { "ConnectionString": "mongodb://mongo:27017" },
      "Redis": { "ConnectionString": "redis:6379" },
      "Grpc": { "InventoryServiceAddress": "http://inventory:8080" },
      "Jwt": { "Issuer": "kart-identity-service", "JwksUri": "http://identity:8080/.well-known/jwks.json" }
    },
    "kart-order-service": {
      "ConnectionStrings": { "OrderDatabase": "Host=postgres;Port=5432;Database=kart_order;Username=postgres;Password=postgres" },
      "Mongo": { "ConnectionString": "mongodb://mongo:27017", "Database": "kart_order_read" },
      "Inventory": { "BaseUrl": "http://inventory:8080" },
      "Payment": { "BaseUrl": "http://payment:8080" }
    },
    "kart-payment-service": {
      "ConnectionStrings": { "PaymentDatabase": "Host=postgres;Port=5432;Database=kart_payment;Username=postgres;Password=postgres" },
      "Mongo": { "ConnectionString": "mongodb://mongo:27017", "Database": "kart_payment_read" },
      "Gateway": { "SigningSecrets": { "simulated": "dev-simulated-gateway-signing-secret" } }
    },
    "kart-offer-service": {
      "ConnectionStrings": { "OfferDatabase": "Host=postgres;Port=5432;Database=kart_offer;Username=postgres;Password=postgres" },
      "Mongo": { "ConnectionString": "mongodb://mongo:27017", "Database": "kart_offer_read" }
    },
    "kart-wishlist-service": {
      "ConnectionStrings": { "WishlistDb": "Host=postgres;Port=5432;Database=kart_wishlist;Username=postgres;Password=postgres" },
      "Mongo": { "ConnectionString": "mongodb://mongo:27017" },
      "Redis": { "ConnectionString": "redis:6379" },
      "ProductService": { "BaseUrl": "http://product:8080" },
      "Jwt": { "Issuer": "kart-identity-service", "JwksUri": "http://identity:8080/.well-known/jwks.json" }
    },
    "kart-notification-service": {
      "ConnectionStrings": { "NotificationDb": "Host=postgres;Port=5432;Database=kart_notification;Username=postgres;Password=postgres" }
    },
    "kart-delivery-tracking-service": {
      "Mongo": { "ConnectionString": "mongodb://mongo:27017" },
      "Carriers": { "demo-carrier": { "WebhookSharedSecret": "dev-demo-carrier-webhook-secret" } }
    },
    "kart-admin-service": {
      "ConnectionStrings": { "AdminDatabase": "Host=postgres;Port=5432;Database=kart_admin;Username=postgres;Password=postgres" },
      "IdentityClientCredentials": { "ClientId": "admin-service", "ClientSecret": "dev-admin-service-client-secret", "Scope": "admin" },
      "DownstreamServices": {
        "Product": { "BaseUrl": "http://product:8080" },
        "Category": { "BaseUrl": "http://category:8080" },
        "Offer": { "BaseUrl": "http://offer:8080" },
        "Identity": { "BaseUrl": "http://identity:8080" },
        "Inventory": { "BaseUrl": "http://inventory:8080" }
      }
    }
  }
}
EOF

# One host-side log directory per service, matching docker-compose.yml's
# ./compose/globalconfig/logs/<name>:/var/log/kart/kart-<name>-service mounts (host side keeps
# the short <name>; only the container-side destination needs the service's full name).
for name in identity category user product search inventory cart order payment offer wishlist notification delivery-tracking admin; do
  mkdir -p "$OUT_DIR/logs/$name"
done

touch "$OUT_DIR/.generated"
echo "Done. Wrote $OUT_DIR/global.json (14 service blocks) + $OUT_DIR/logs/<service>/ mount points."
