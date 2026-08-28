#!/usr/bin/env bash
# Keeps your three free DuckDNS hostnames pointed at this VM's current public IP. DuckDNS
# doesn't need this often (Oracle Free Tier VMs keep a stable public IP across reboots unless
# you explicitly release it), but running it on every boot + every 6h is cheap insurance against
# a rare IP change silently breaking every URL on your resume.
#
# Setup (one-time, on the VM):
#   1. Sign in to https://www.duckdns.org with any OAuth account (free, no card).
#   2. Add three subdomains: kart-web-demo, kart-admin-demo, kart-api-demo (or your own names —
#      just keep them consistent with Caddyfile). All three share the one account token shown
#      on the DuckDNS dashboard.
#   3. cp duckdns-update.sh ~/duckdns-update.sh && chmod +x ~/duckdns-update.sh
#   4. Fill in DUCKDNS_TOKEN below (or export it in the environment instead of hardcoding it).
#   5. Run once by hand to confirm it works, then add to crontab:
#        (crontab -l 2>/dev/null; echo "@reboot ~/duckdns-update.sh"; \
#         echo "0 */6 * * * ~/duckdns-update.sh") | crontab -

set -euo pipefail

DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-PASTE_YOUR_DUCKDNS_TOKEN_HERE}"
DOMAINS="kart-web-demo,kart-admin-demo,kart-api-demo"

if [[ "$DUCKDNS_TOKEN" == "PASTE_YOUR_DUCKDNS_TOKEN_HERE" ]]; then
  echo "Set DUCKDNS_TOKEN (env var or edit this script) before running." >&2
  exit 1
fi

response="$(curl -fsS "https://www.duckdns.org/update?domains=${DOMAINS}&token=${DUCKDNS_TOKEN}&ip=")"
echo "$(date -Iseconds) duckdns update -> ${response}"

if [[ "$response" != OK* ]]; then
  echo "DuckDNS update failed — check the token and domain names." >&2
  exit 1
fi
