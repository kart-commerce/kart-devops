# kart-devops

Reusable GitHub Actions workflows, pipeline templates, and shared linter/scanner config for every
`kart-<name>-service` repo (PLATFORM_BLUEPRINT.md S2.4 "Reusable GitHub Actions workflows... consumed
via `workflow_call`"; kart-conventions.md "CI: service repos call the reusable workflow published
from kart-devops"). Nothing here is deployed - it's consumed by other repos' `.github/workflows/ci.yml`.

## Full platform stack (`docker-compose.yml`)

Brings up every real (scaffolded) backend service, `kart-api-gateway`, both Angular apps
(`kart-web`, `kart-admin-web`), and one shared Postgres/Mongo/Redis/RabbitMQ/OpenSearch, all on
one Docker network, with one command. This is the fast day-to-day coding loop — see
[kart-infra](../kart-infra) for the separate kind+Helm path that validates a real Kubernetes
deployment ([ADR-0001](../kart-infra/docs/adr/0001-local-cluster-tool-kind.md)); the two are
intentionally different tools for different jobs, not competing choices. kind+Helm proves the
production-shaped deployment story; this stack is for iterating on code across many services at
once without a rebuild-image/helm-upgrade/wait-for-rollout cycle on every change.

**Excluded on purpose:** `kart-review-service`, `kart-shipping-service`,
`kart-recommendation-service`, `kart-analytics-service`, `kart-admin-service` have no code yet
(stub repos — just a README). Add them here once they're actually scaffolded. `kart-api-gateway`
itself was also a stub before this stack existed — this repo's compose work included scaffolding
a real (if intentionally minimal) YARP gateway for it; see that repo's own README for scope.

### Quickstart

```bash
scripts/dev-up.sh          # generates dev-only secrets on first run, then docker compose up --build -d
scripts/migrate-all.sh     # apply EF Core migrations (run once, and again after pulling new migrations)
scripts/dev-logs.sh        # tail every service's logs together (or dev-logs.sh <service> for one)
scripts/dev-down.sh        # stop everything (-v also wipes data volumes)
```

Then:

| What | URL |
|---|---|
| API Gateway (what the FE talks to) | http://localhost:8100 |
| kart-web (storefront) | http://localhost:4210 |
| kart-admin-web (back office) | http://localhost:4300 |
| RabbitMQ management UI | http://localhost:15672 (`kart` / `kart123`) |
| Shared observability (Grafana etc.) | run `docker compose -f docker-compose.observability.yml up -d` alongside — see below |

### Why one shared `global.json`, not plain `environment:` vars

Every service calls `Kart.Shared.Configuration`'s `AddKartGlobalConfig(serviceName)`, which layers
a `GlobalConfig:Path` JSON file on top of whatever config exists **last** — so it silently wins
over a same-named `environment:` value, and the app refuses to boot if that path doesn't resolve
at all. This stack points every container's `GlobalConfig:Path` at the same file (throwaway
local-dev secrets — a JWT signing keypair, shared dev DB/broker credentials, cross-service URLs
already pointed at this compose network's service names), shaped as a `Global` section
(platform-wide defaults every service inherits) plus one `Services:<name>` block per service (that
service's own secrets). `AddKartGlobalConfig` picks out only the `Global` + `Services:<serviceName>`
keys that apply to a given container, using the literal service name each container's own
`Program.cs` already passes in.

**Where that file actually lives is never written down in this repo.** Every service's volume
mount in `docker-compose.yml` reads `${GLOBALCONFIG_PATH}:/app/globalconfig.json:ro` — a variable,
not a literal path — sourced from `globalconfig.local.env` (gitignored, per-machine, one line:
`GLOBALCONFIG_PATH=/wherever/yours/is`; see
[`globalconfig.local.env.example`](globalconfig.local.env.example)). `scripts/dev-up.sh` sources it
the same way it sources `ports.env` and fails fast with an actionable message if it's missing or
points at nothing, rather than letting every container crash-loop on a confusing
`GlobalConfig:Path` error. The file it should point at doesn't exist until you create one — copy
[`compose/globalconfig/global.json.example`](compose/globalconfig/global.json.example) *anywhere
you like* and fill in its two `Jwt`/`Mfa` placeholders (that file's own comments explain how, and
why they matter more than everything else in it — they're the only two values here that
decrypt/verify data that outlives a container restart) — then point `GLOBALCONFIG_PATH` at wherever
you put it. If you also run `kart-identity-service` bare-metal against
`kart-internals/globalconfig.json`, reuse that file's `Jwt.SigningKey.PrivateKeyPem` and
`Mfa.Encryption.KeyBase64` values here instead of generating fresh ones, so tokens and MFA
enrollments stay valid across both.

Each container also mounts `compose/globalconfig/logs/<service>/` at `/var/log/kart/<service>` —
`global.json`'s `Global:LogRoot` is `/var/log/kart`, so `Kart.Shared.Configuration` computes the
exact same `{LogRoot}/{serviceName}` log directory formula Docker and bare-metal local dev both
use (bare-metal's `kart-internals/globalconfig.json` just sets a different, host-absolute
`LogRoot`) — `tail -f compose/globalconfig/logs/product/kart-product-service-*.log` reaches the
same file the container's Serilog file sink writes.

### Ports

**[`ports.env`](ports.env) is the single source of truth** for every host port in the table
below -- not a secret (unlike `compose/globalconfig/`/`globalconfig.local.env`), committed to
git, read directly by this file's own `${..._PORT}` interpolation. `scripts/dev-up.sh`/
`dev-down.sh`/`dev-logs.sh` already pass `docker compose --env-file ports.env --env-file
globalconfig.local.env`; run both flags yourself if you're calling `docker compose` directly
instead of through those scripts. Change a port in exactly one place -- `ports.env` -- then
update its non-Docker consumers listed below to match.

| Service | Host port |
|---|---|
| gateway | 8100 |
| identity | 8081 |
| user | 8082 |
| product | 8083 |
| category | 8084 |
| search | 8085 |
| inventory | 8086 |
| cart | 8087 |
| order | 8088 |
| payment | 8089 |
| offer | 8090 |
| wishlist | 8091 |
| notification | 8092 |
| delivery-tracking | 8093 |
| admin | 8094 |
| web / admin-web | 4210 / 4300 |
| postgres / mongo / redis / rabbitmq / opensearch | 5433 / 27018 / 6380 / 5673 (+15672 UI) / 9200 |

Several host ports are shifted off their conventional defaults (gateway 8100 not 8080, web 4210
not 4200, postgres 5433, mongo 27018, redis 6380, rabbitmq 5673) because dev machines commonly
already have something bound to the default -- a local Postgres/Mongo/Redis install, another
RabbitMQ container, or an `ng serve` in progress. Containers still talk to each other by their
compose service name on the *container's own* default port (`redis:6379`, `postgres:5432`, etc.)
regardless of the host-side mapping.

**These are the canonical ports, full stop** -- every backend service's own repo points at the
same host port for local, non-Docker dev too, not a random Visual-Studio-assigned port. How each
kind of consumer stays in sync, since a JSON/YAML config file can't literally import a value from
`ports.env` the way code can:

- **Compiled code** (C# option-class defaults, e.g. `kart-cart-service`'s `GrpcOptions`,
  `kart-wishlist-service`'s `ProductServiceOptions`) references
  `Kart.Shared.Configuration.KartServiceEndpoints` -- the genuinely DRY, single-copy case, since
  `kart-shared` is already a cross-repo dependency every service's `Infrastructure` project can
  reference. See that class's own header comment.
- **`kart-web`/`kart-admin-web`** converge every port their BFF/Angular code touches into one
  `src/app/core/config/service-endpoints.ts` per app (framework-agnostic, importable from both
  the browser-bundled `app-config.ts` and the Node-only `server/bff/*` clients) -- also genuinely
  DRY *within* each app.
- **Each service's own standalone `docker-compose.yml`** uses `${SERVICE_PORT:-<default>}`
  interpolation -- `source ../kart-devops/ports.env` before `docker compose up` to pull the live
  value from this file's registry; the `:-<default>` half is only a fallback for running that
  repo fully standalone, with no `kart-devops` checkout alongside it.
- **`launchSettings.json`, `appsettings.Development.json`, `.env.example`, `proxy.conf.json`** are
  necessarily literal -- `dotnet run`/Compose/Node's `--env-file` have no mechanism to import a
  value from another file at the JSON/text level without a code-generation step (this repo has no
  such step for these files, unlike `compose/globalconfig/`'s generated secrets). Each of these
  is commented in place pointing back at `ports.env` as its source of truth; keeping them in sync
  on a port change is a manual, but small and clearly-flagged, step.

The intent either way: a service (or the whole stack) reachable at the same port whether it's
running via this compose file, a service's own standalone `docker-compose.yml`, or a bare
`dotnet run` -- no more "which port is identity on today" drift between how devops brings it up
and how a developer runs it locally. `kart-api-gateway`'s own `appsettings.Development.json`
repoints its route table's cluster addresses at `localhost:<port>` the same way, for running the
whole stack bare-metal through the gateway without Docker at all.

Infra ports (Postgres/Mongo/Redis/RabbitMQ/OpenSearch) are the one deliberate exception: each
service's own standalone `docker-compose.yml` runs its own full-fidelity infra (sharded Mongo,
a dedicated RabbitMQ user, etc. -- see "Known scope limits" above) on its own, independently
chosen host ports, so those are *not* unified with this stack's shared-infra ports above; running
a service's own compose file and this stack side by side is not a supported combination anyway.

### Known scope limits (flagged, not silently dropped)

- **Gateway routing extends beyond its approved release-0 scope.** `kart-api-gateway`'s own
  `tickets.md` (GW-1) only scoped routing to `kart-identity-service` + `kart-category-service`;
  this stack's gateway routes to all 13 real services using a defensible default (public-catalog
  GET routes anonymous, everything else requires a bearer token) since that's what a stack
  bringing up 13 services actually needs. Not yet built: Redis-backed revocation check (GW-4),
  tiered rate limiting (GW-5), per-cluster circuit breaking (GW-7) — routing + JWT validation +
  forwarding only.
- **No sharded Mongo, no per-service RabbitMQ users.** Several services' own individual
  `docker-compose.yml` run a 4-node sharded Mongo cluster or a service-specific RabbitMQ user —
  simplified here to one single-node Mongo and one shared RabbitMQ user (`kart`/`kart123`) across
  every service, since sharding/isolation is a staging concern (kind+Helm's job), not a feature-
  dev-loop concern.
- **App containers have no `HEALTHCHECK`.** Only ~7 of 13 services expose `/health/ready` at all,
  and the base ASP.NET runtime image has no `curl`/`wget` to probe it with anyway. `depends_on`
  gates on the *infra* containers' health (Postgres/Mongo/Redis/RabbitMQ all have real
  healthchecks) but not on other app containers being fully ready — each service's own
  `StartupConnectivityChecks` will log loudly if it raced a dependency; `docker compose restart
  <service>` if one comes up before what it needs.

### Real bugs this stack's first end-to-end run surfaced and fixed

None of these were compose-wiring issues — every one reproduces in a plain `docker build`/`dotnet
run` of the affected repo alone. Bringing up all 13 services together for the first time is what
actually exercised these paths:

- **Missing `Directory.Build.props`/`nuget.config`/`packages/`/`contracts/` COPY lines** in several
  services' own `Dockerfile` (`kart-identity-service`, `kart-category-service`,
  `kart-inventory-service`, `kart-user-service`, `kart-cart-service`, `kart-product-service`,
  `kart-search-service`) — each had never actually been through a real `docker build` before.
- **No `.dockerignore` excluding `**/bin/`, `**/obj/`, `**/appsettings.Local.json`** in several
  repos (`kart-identity-service`, `kart-user-service`, `kart-cart-service`, `kart-payment-service`,
  `kart-wishlist-service`) plus the shared `kart-commerce/.dockerignore` this repo's own scripts
  generate (needed for the 5 services that build with `kart-commerce/` as context) — without it, a
  developer's own stale `obj/` output or personal `appsettings.Local.json` (pointing
  `GlobalConfig:Path` at their own machine) gets copied into the image and either corrupts the
  restore or makes the container try to read a path that only exists on the original dev's laptop.
- **`kart-category-service` and `kart-user-service`'s own `RabbitMqOptions` class never had
  `UserName`/`Password` properties at all** — only `kart-identity-service` (the actual reference
  implementation) had them wired through to `RabbitMqConnectionSettings`. Both always connected as
  RabbitMQ's default `guest` user, which only works over a literal loopback connection — fixed to
  match identity's already-correct pattern.
- **`kart-wishlist-service`'s `DigestFlushHostedService` (singleton) directly constructor-injected
  a `Scoped` service** (`IWishlistDigestAccumulator`) — .NET's DI container only validates this at
  startup when `ASPNETCORE_ENVIRONMENT=Development` (the default), which this service had
  apparently never actually been booted under before. Fixed the same way the same file already
  handled its `ISender` dependency: resolve it from `IServiceScopeFactory.CreateScope()` instead.
- **`kart-admin-web`'s Express 5 SPA-fallback route (`'/*splat'`) never matched the site root**
  (`path-to-regexp` v8's bare `*name` wildcard requires >=1 path segment) — every other route
  worked, only `GET /` 404'd. Fixed to `'/{*splat}'` (the optional-segment form).
- **`@angular/ssr`'s built-in Host-header SSRF guard** rejects any Host it doesn't recognize —
  needs `NG_ALLOWED_HOSTS` set (hostname only, no port — the check strips the port before
  comparing) since the browser reaches `kart-web` on host port 4210, not its own internal 4000.

## Workflows

### `.github/workflows/dotnet-service-ci.yml`

Reusable CI for .NET (Clean Architecture + Vertical Slice) services. Covers the .NET-applicable rows
of PLATFORM_BLUEPRINT.md's Quality Gate table (S11): coding-standards formatting, a vulnerable-package
security scan, and unit/integration/contract tests in one `dotnet test` pass (GitHub-hosted runners
have Docker preinstalled, so Testcontainers-backed integration tests need no extra setup). Optionally
builds the calling repo's `Dockerfile` as a smoke check.

**Usage** (in the calling repo's `.github/workflows/ci.yml`):

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  ci:
    uses: kart-commerce/kart-devops/.github/workflows/dotnet-service-ci.yml@main
    with:
      dotnet-version: "8.0.x"
      solution-path: KartCategoryService.sln
```

| Input | Required | Default | Description |
|---|---|---|---|
| `dotnet-version` | yes | - | .NET SDK version to install, e.g. `8.0.x`. |
| `solution-path` | yes | - | Path to the repo's `.sln` file, relative to the repo root. |
| `run-docker-build` | no | `true` | Also build the repo's `Dockerfile` as a smoke check. Set `false` for a repo with no Dockerfile. |

**Prerequisites this workflow assumes** (every scaffolded service should already have these - see
`agent-reusables/docs/standards/folder-structure.md`):
- A `Dockerfile` at the repo root (unless `run-docker-build: false`).
- `dotnet format --verify-no-changes` passes cleanly - run `dotnet format` locally before pushing if
  this gate fails.
- A `.dockerignore` excluding `**/bin/` and `**/obj/` - without it, `COPY src/ src/`-style Dockerfile
  steps copy the host's own stale build output into the image and the publish step fails looking for
  packages that "restore" already fetched (this bit kart-category-service's own first Dockerfile).

### `.github/workflows/angular-app-ci.yml`

Reusable CI for `kart-web`/`kart-admin-web` (and any other Angular app repo). Mirrors
`dotnet-service-ci.yml`'s shape for the Node ecosystem: `npm ci`, lint (coding-standards gate),
`ng test` in headless-Chrome mode (unit/component-test gate), `npm run build`, and an optional
Docker build smoke check.

**Usage:**

```yaml
jobs:
  ci:
    uses: kart-commerce/kart-devops/.github/workflows/angular-app-ci.yml@main
    with:
      node-version: "20.x"
```

| Input | Required | Default | Description |
|---|---|---|---|
| `node-version` | yes | - | Node.js version to install, e.g. `20.x`. |
| `working-directory` | no | `.` | Directory containing the app's `package.json`. |
| `run-docker-build` | no | `true` | Also build the repo's `Dockerfile` as a smoke check. |

### `.github/workflows/docker-build-push.yml`

Builds a calling repo's multi-stage `Dockerfile` and pushes it to GitHub Container Registry (`ghcr.io`)
tagged `:latest` and `:<git-sha>` - but only on a push to the repo's default branch; PR branches still
build (a smoke check) but never push. Implements the Quality Gate table's (S11) "Docker Build Success"
row.

| Input | Required | Default | Description |
|---|---|---|---|
| `image-name` | yes | - | Image name, without registry/owner prefix, e.g. `kart-category-service`. |
| `dockerfile-path` | no | `Dockerfile` | Path to the Dockerfile, relative to the repo root. |
| `context` | no | `.` | Docker build context, relative to the repo root. |

Requires `permissions: packages: write` in the calling job (already declared inside this reusable
workflow, but GitHub also requires the caller's workflow to not restrict it further).

### `.github/workflows/contract-test-runner.yml`

Consumer-driven contract verification for a provider service, called from that service's own CI. No
real Pact Broker exists yet (`docs/client/api-strategy.md` S7) - this runs
[`oasdiff`](https://github.com/oasdiff/oasdiff) (`tufin/oasdiff` Docker image) to diff each registered
consumer's committed contract snapshot ("base") against the provider's current `api-contract.yaml`
("revision") and fails the gate on a breaking change. Implements the Quality Gate table's (S11)
"Contract Tests" row. A hosted Pact Broker is a planned future upgrade once enough real consumers exist.

| Input | Required | Default | Description |
|---|---|---|---|
| `provider-contract-path` | yes | - | Path to the provider's current `api-contract.yaml`. |
| `consumers` | yes | - | JSON array of `{name, repo, contract-snapshot-path, ref?}` consumer registrations. |
| `fail-on` | no | `ERR` | Minimum `oasdiff` severity that fails the gate: `ERR`, `WARN`, or `INFO`. |

Optional secret: `consumer-checkout-token` - a token with read access to consumer repos, for cross-repo
checkout of private consumer repos (falls back to the default `GITHUB_TOKEN` otherwise).

### `.github/workflows/openapi-client-codegen.yml`

Implements `docs/client/api-strategy.md` S1: regenerates a typed Angular `HttpClient` client from a
service's `api-contract.yaml` via `openapi-generator-cli` (Docker image), then fails the build if
regeneration produced an uncommitted diff - i.e. it's also the "generated client is up to date" check,
not just a generator.

| Input | Required | Default | Description |
|---|---|---|---|
| `contract-path` | yes | - | Path to the service's `api-contract.yaml`. |
| `output-dir` | yes | - | Directory the generated client is emitted into, e.g. `core/http/generated/category-service`. |
| `npm-name` | no | `""` | `npmName` generator property for the generated client package. |
| `generator-image-tag` | no | `v7.9.0` | Pinned `openapitools/openapi-generator-cli` image tag. |
| `fail-on-diff` | no | `true` | Fail the build on an uncommitted regeneration diff. Set `false` for a pure regenerate-only run. |

### `docker-compose.observability.yml`

The shared local-dev Grafana + Loki + Tempo + Prometheus (+ OpenTelemetry Collector) stack
(`agent-reusables/docs/standards/observability-standards.md`, "Local Development"). Owned once,
centrally, here - every service repo's own README should point developers at this file rather than
copy-pasting one. See [`observability/README.md`](observability/README.md) for exposed ports, the
default Grafana login, and usage.

## What's not here yet

Terraform/Helm/K8s bootstrap is `kart-infra`'s job, not this repo's (PLATFORM_BLUEPRINT.md S2.4). A
shared `.editorconfig`/analyzer ruleset consumed by multiple services is a natural next addition here
once a second .NET service exists to confirm what's actually shared versus per-service. A real, hosted
Pact Broker is a planned upgrade to `contract-test-runner.yml` once enough consumers exist.
