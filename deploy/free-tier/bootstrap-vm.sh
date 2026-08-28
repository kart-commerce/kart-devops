#!/usr/bin/env bash
# One-time setup for a fresh Oracle Cloud "Always Free" Ampere A1 VM (Ubuntu 22.04/24.04).
# Run this AS THE VM'S NORMAL USER (e.g. `ubuntu`), not root — it uses sudo where needed.
#
# What it does:
#   1. Installs Docker Engine + the Compose plugin from Docker's own apt repo (Ubuntu's default
#      repo `docker-compose` package is the old, unsupported v1 — this stack's docker-compose.yml
#      needs the `!reset` merge tag, only supported by Compose v2.24+).
#   2. Opens 80/443 in the VM's own OS-level firewall. IMPORTANT: Oracle's stock Ubuntu image
#      ships iptables rules that block everything but SSH by default, ON TOP OF whatever you
#      configure in the OCI console's Security List/NSG for the VCN — both layers must allow
#      80/443, or every request just times out with no obvious error either side. This script
#      only handles the OS layer; you still have to add Ingress Rules for 80/443 in the OCI
#      console yourself (Networking -> Virtual Cloud Networks -> your VCN -> Security Lists).
#   3. Clones every repo the compose stack needs as siblings under ~/kart-commerce/, matching
#      the relative `../kart-*-service` paths kart-devops/docker-compose.yml's build contexts
#      expect.
#
# Usage: ./bootstrap-vm.sh <github-org-or-username>
#   e.g. ./bootstrap-vm.sh kart-commerce

set -euo pipefail

GH_OWNER="${1:?Usage: ./bootstrap-vm.sh <github-org-or-username>}"
WORKDIR="${HOME}/kart-commerce"

echo "==> Installing Docker Engine + Compose plugin"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg ufw
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
echo "    docker compose version: $(sudo docker compose version)"

echo "==> Installing .NET 8 SDK + dotnet-ef (needed for scripts/migrate-all.sh, which runs EF Core"
echo "    migrations from the host shell against postgres's loopback-only port — see README)"
# Ubuntu's own repo carries dotnet-sdk-8.0 on 22.04/24.04 (both arm64 and amd64) as of this
# writing; if `apt-get install` below 404s for your release, fall back to Microsoft's installer
# instead: curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin --channel 8.0
sudo apt-get install -y dotnet-sdk-8.0
export PATH="$PATH:$HOME/.dotnet/tools"
dotnet tool install --global dotnet-ef || dotnet tool update --global dotnet-ef
grep -qxF 'export PATH="$PATH:$HOME/.dotnet/tools"' ~/.bashrc || \
  echo 'export PATH="$PATH:$HOME/.dotnet/tools"' >> ~/.bashrc

echo "==> Opening 80/443 in the VM's OS firewall (iptables, Oracle's default — ufw is layered on"
echo "    top for convenience but Oracle's stock rules bypass ufw's own chain, so both are set)"
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save 2>/dev/null || sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo "==> Cloning repos into ${WORKDIR}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
REPOS=(
  kart-devops kart-shared kart-api-gateway kart-web kart-admin-web kart-internals
  kart-identity-service kart-category-service kart-user-service kart-product-service
  kart-search-service kart-inventory-service kart-cart-service kart-order-service
  kart-payment-service kart-offer-service kart-wishlist-service kart-notification-service
  kart-delivery-tracking-service kart-admin-service kart-recommendation-service
)
for repo in "${REPOS[@]}"; do
  if [[ -d "$repo/.git" ]]; then
    echo "    $repo already cloned, pulling latest default branch"
    git -C "$repo" pull --ff-only
  else
    git clone --depth 1 "https://github.com/${GH_OWNER}/${repo}.git"
  fi
done

cat <<EOF

Done. Next steps (see this folder's README.md for the full walkthrough):
  1. Log out and back in (or 'newgrp docker') so your user's docker-group membership takes effect.
  2. In the OCI console, add Ingress Rules for TCP 80 and 443 to your VCN's Security List —
     the OS-level firewall above is only half of what Oracle blocks by default.
  3. cd ${WORKDIR}/kart-devops && ./deploy/free-tier/generate-secrets.sh
  4. Fill in Caddyfile + docker-compose.prod.yml's YOUR_DOMAIN/YOUR_EMAIL placeholders.
  5. Set up DuckDNS (duckdns-update.sh's header comment) and run it once.
  6. Bring the stack up (see README.md's "Bring it up" section).
EOF
