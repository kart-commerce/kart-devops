#!/usr/bin/env bash
# Generates a REAL, one-time RS256 signing key + AES-256 MFA key for this deployment and writes
# a ready-to-use compose/globalconfig/global.json — never reuse the dev keys from
# global.json.example on anything public. Also writes infra.env with random Postgres/RabbitMQ
# passwords instead of the example's throwaway `postgres`/`kart123` defaults.
#
# Run from kart-devops/ (i.e. `./deploy/free-tier/generate-secrets.sh`) on the VM, once, before
# first boot. Both generated secrets are irreplaceable once real users/orders exist behind them
# (see global.json.example's own _comment_Jwt / _comment_Mfa) — back up
# compose/globalconfig/global.json somewhere off the VM after this runs.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."   # -> kart-devops/

if [[ -f compose/globalconfig/global.json ]]; then
  echo "compose/globalconfig/global.json already exists — refusing to overwrite. Delete it" >&2
  echo "first if you really want to regenerate (this invalidates every issued token/enrolled" >&2
  echo "MFA credential)." >&2
  exit 1
fi

JWT_PEM_RAW="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)"
JWT_PEM_ESCAPED="$(printf '%s' "$JWT_PEM_RAW" | sed ':a;N;$!ba;s/\n/\\n/g')"
MFA_KEY="$(openssl rand -base64 32)"
PG_PASSWORD="$(openssl rand -hex 16)"
RABBITMQ_PASSWORD="$(openssl rand -hex 16)"
ADMIN_CLIENT_SECRET="$(openssl rand -hex 16)"
GATEWAY_SIGNING_SECRET="$(openssl rand -hex 16)"

cp compose/globalconfig/global.json.example compose/globalconfig/global.json
python3 - "$JWT_PEM_ESCAPED" "$MFA_KEY" "$PG_PASSWORD" "$RABBITMQ_PASSWORD" "$ADMIN_CLIENT_SECRET" "$GATEWAY_SIGNING_SECRET" <<'PYEOF'
import json, sys, re

jwt_pem, mfa_key, pg_pw, rmq_pw, admin_secret, gw_secret = sys.argv[1:7]
path = "compose/globalconfig/global.json"
with open(path) as f:
    text = f.read()
data = json.loads(text)

data["Global"]["RabbitMq"]["Password"] = rmq_pw
data["Services"]["kart-identity-service"]["Jwt"]["SigningKey"]["PrivateKeyPem"] = jwt_pem
data["Services"]["kart-identity-service"]["Mfa"]["Encryption"]["KeyBase64"] = mfa_key
data["Services"]["kart-identity-service"]["ServicePrincipalSeeds"][0]["ClientSecret"] = admin_secret
data["Services"]["kart-admin-service"]["IdentityClientCredentials"]["ClientSecret"] = admin_secret
data["Services"]["kart-payment-service"]["Gateway"]["SigningSecrets"]["simulated"] = gw_secret

# Every "...Username=postgres;Password=postgres" connection string gets the new password.
def swap_pg_password(s):
    return re.sub(r"Password=postgres\b", f"Password={pg_pw}", s)

def walk(obj):
    if isinstance(obj, dict):
        return {k: walk(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [walk(v) for v in obj]
    if isinstance(obj, str):
        return swap_pg_password(obj)
    return obj

data = walk(data)
del data["_comment"]
for svc in data["Services"].values():
    svc.pop("_comment", None)
    svc.pop("_comment_Jwt", None)
    svc.pop("_comment_Mfa", None)

with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

cat > infra.env <<EOF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${PG_PASSWORD}
RABBITMQ_DEFAULT_USER=kart
RABBITMQ_DEFAULT_PASS=${RABBITMQ_PASSWORD}
EOF

mkdir -p "$(dirname compose/postgres-init/01-create-databases.sql)" # no-op, just documenting order
echo "$(pwd)/compose/globalconfig/global.json" > /tmp/kart-globalconfig-path

cat <<EOF

Generated:
  compose/globalconfig/global.json   (RS256 signing key, AES-256 MFA key, real Postgres/
                                       RabbitMQ passwords, admin service-principal secret)
  infra.env                          (matching Postgres/RabbitMQ bootstrap credentials)

Now:
  1. echo "GLOBALCONFIG_PATH=\$(pwd)/compose/globalconfig/global.json" > globalconfig.local.env
  2. Back up compose/globalconfig/global.json somewhere OFF this VM (password manager, encrypted
     note, etc.) — losing it locks out every enrolled MFA user and invalidates every session.
  3. Both compose/globalconfig/global.json and infra.env are already gitignored — never commit
     them.
EOF
