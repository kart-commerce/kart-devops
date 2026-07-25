# kart-devops

Reusable GitHub Actions workflows, pipeline templates, and shared linter/scanner config for every
`kart-<name>-service` repo (PLATFORM_BLUEPRINT.md S2.4 "Reusable GitHub Actions workflows... consumed
via `workflow_call`"; kart-conventions.md "CI: service repos call the reusable workflow published
from kart-devops"). Nothing here is deployed - it's consumed by other repos' `.github/workflows/ci.yml`.

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
