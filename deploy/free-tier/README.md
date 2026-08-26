# Free-tier deploy: the whole platform, live, for $0/month

Runs the entire stack this repo's own `docker-compose.yml` + `docker-compose.observability.yml`
define — 15 backend services, the gateway, both Angular apps, Postgres/Mongo/Redis/RabbitMQ/
Kafka/OpenSearch, and the Grafana/Loki/Tempo/Prometheus/OTel observability stack — on one
always-on VM, at zero recurring cost. Written for a portfolio/interview demo, not production
scale; read "What this deliberately doesn't do" at the bottom before treating it as more than
that.

## Why this stack, not a PaaS

Render/Railway/Fly-style free tiers cap out around 512MB RAM per service and sleep on
inactivity — fine for one service, unworkable for 15 interdependent .NET services plus Kafka and
OpenSearch (cascading cold-starts on every first request, and you'd need 15+ separate free
services that can't share a Docker network). AWS/GCP/Azure's free-tier VMs are 1GB RAM, nowhere
near enough. **Oracle Cloud's "Always Free" Ampere A1 shape** (up to 4 OCPUs / 24GB RAM, ARM64,
genuinely free forever, not a 12-month trial) is the only free option with enough headroom to run
this stack as one Docker Compose project, which is exactly what's already built and tested
locally — no re-architecting needed, just a production-hardening layer on top.

Trade-off to know going in: Oracle's Ampere A1 capacity is sometimes scarce in popular regions —
if instance creation fails with an out-of-capacity error, retry in a different Availability
Domain, try again later, or try a different region. This is the main friction point in this whole
plan; everything past provisioning is straightforward.

## Prerequisites

- An Oracle Cloud account (free, needs a card for identity verification — Always Free resources
  are never charged as long as you stay within the free-tier shape/limits).
- This platform's repos pushed to GitHub under an account/org you control (`bootstrap-vm.sh`
  clones them by HTTPS; make them public, or set up a deploy key if you'd rather keep them
  private and still show the live demo).
- A free [DuckDNS](https://www.duckdns.org) account for stable hostnames (no domain purchase
  required).

## Steps

1. **Provision the VM** — OCI console → Compute → Instances → Create Instance. Image: Ubuntu
   22.04 or 24.04 (Canonical, "Always Free Eligible" flagged in the picker). Shape: Ampere
   `VM.Standard.A1.Flex`, 4 OCPUs / 24GB — the "Always Free Eligible" flavor. Add your SSH public
   key. Create.
2. **Open the firewall — both layers.** In the OCI console: your VCN → Security Lists → default
   security list → add Ingress Rules for TCP 80 and 443 from `0.0.0.0/0`. This is a DIFFERENT
   firewall from the VM's own OS-level iptables rules (which `bootstrap-vm.sh` handles) — Oracle
   blocks by default at both layers, and "it works over SSH but the browser just hangs" almost
   always means this step was skipped.
3. **SSH in, then run bootstrap:**
   ```
   scp -r kart-devops/deploy/free-tier ubuntu@<VM_PUBLIC_IP>:~/free-tier-setup
   ssh ubuntu@<VM_PUBLIC_IP>
   chmod +x ~/free-tier-setup/*.sh
   ~/free-tier-setup/bootstrap-vm.sh <your-github-org-or-username>
   ```
   Installs Docker + Compose v2, the .NET 8 SDK (for the EF Core migration step later), opens
   80/443 in the OS firewall, and clones all 21 repos as siblings under `~/kart-commerce/`.
4. **Generate real secrets** (never reuse the dev defaults from `global.json.example` on
   anything public):
   ```
   cd ~/kart-commerce/kart-devops
   cp ~/free-tier-setup/*.sh deploy/free-tier/ -f   # if you didn't clone straight into place
   ./deploy/free-tier/generate-secrets.sh
   echo "GLOBALCONFIG_PATH=$(pwd)/compose/globalconfig/global.json" > globalconfig.local.env
   ```
   Back up `compose/globalconfig/global.json` somewhere off the VM — it holds the RS256 signing
   key and MFA encryption key; losing it after real signups/orders exist locks users out.
5. **Set up DuckDNS.** Register three subdomains under one free account (e.g.
   `kart-web-demo`, `kart-admin-demo`, `kart-api-demo`), copy `duckdns-update.sh` to the VM, fill
   in your token, run it once, then cron it (`@reboot` + every 6h — see the script's own header).
6. **Fill in the two placeholder files:**
   - `Caddyfile` — replace the three `*.duckdns.org` hostnames if you chose different ones, and
     `YOUR_EMAIL` for Let's Encrypt notices.
   - `docker-compose.prod.yml` — replace `YOUR_DOMAIN` (both occurrences) with your storefront's
     DuckDNS hostname.
7. **Bring it up:**
   ```
   cd ~/kart-commerce/kart-devops
   docker network create kart-shared-net
   docker compose --env-file ports.env --env-file globalconfig.local.env --env-file infra.env \
     -f docker-compose.yml -f docker-compose.observability.yml \
     -f deploy/free-tier/docker-compose.prod.yml \
     up -d --build
   ```
   First run compiles 15 .NET services + 2 Angular SSR apps from source (base images are
   multi-arch, so this runs natively on ARM64, no emulation) — expect 20–40 minutes and heavy
   CPU. `docker compose ps` to watch it settle; Caddy won't get a valid cert until the app
   containers it proxies to are actually up.
8. **Migrate + seed** (once, and again after any migration-adding change):
   ```
   ./scripts/migrate-all.sh
   ./deploy/free-tier/seed-demo-data.sh
   ```
9. **Install the systemd unit** so a VM reboot (kernel patching, etc.) brings everything back:
   ```
   sudo cp deploy/free-tier/kart-platform.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable kart-platform
   ```
10. **Verify:** `https://kart-web-demo.duckdns.org` loads the storefront,
    `https://kart-admin-demo.duckdns.org` loads the back office, `https://kart-api-demo.duckdns.org`
    responds. Put a free [UptimeRobot](https://uptimerobot.com) monitor (5-min interval, free
    tier) on the storefront URL — a live uptime badge in the README is a small, concrete signal
    that this isn't a one-time screenshot.

## Redeploying after a change

```
cd ~/kart-commerce/<changed-repo> && git pull
cd ~/kart-commerce/kart-devops
sudo systemctl restart kart-platform    # rebuilds via ExecStart, same as step 7
```

## Known gaps to close before pointing recruiters at the URL

- **Public-facing `localhost` defaults.** This overlay fixes the two confirmed at doc-writing
  time (`kart-web`'s `NG_ALLOWED_HOSTS`/`IDENTITY_SERVICE_PUBLIC_BASE_URL`, and
  `kart-identity-service`'s `PublicWebBaseUrl` in `appsettings.json`, which still needs a manual
  override — grep each service's `appsettings.json`/`appsettings.Docker.json` for `localhost`
  before calling this done, especially anything involved in an OAuth/social-login redirect or a
  CORS allow-list).
- **Rate limiting / abuse protection.** `kart-devops/README.md` already flags that
  Redis-backed token revocation, tiered rate limiting, and per-cluster circuit breaking aren't
  built into the gateway yet. A public URL with no rate limit in front of it is fine for a
  low-traffic portfolio demo but worth a line in your own notes — and an easy, free follow-up:
  add Cloudflare in front (needs owning the domain in Cloudflare's nameservers, so only possible
  once you're past DuckDNS onto a real domain).
- **Demo data resets.** Nothing here wipes/reseeds periodically — if you expect random visitors
  to create test orders/accounts, decide whether "state doesn't stay clean forever" is
  acceptable for a demo (it usually is) or whether you want a cron job that resets the DB nightly.

## What this deliberately doesn't do

- No horizontal scaling, no load balancer, no multi-node anything — one VM, single points of
  failure everywhere. That's the correct trade-off for a $0 portfolio demo; don't present it as
  more than that in an interview, but do be ready to talk about exactly *what* you'd change for
  real scale (that conversation is worth more than the uptime badge).
- No managed backups for Postgres/Mongo — the seeded demo data isn't precious, but if you start
  caring about not losing it, add a cron `pg_dump`/`mongodump` to Oracle's free Object Storage
  tier (10GB free) rather than treating this as solved.
