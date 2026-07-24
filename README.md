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

## What's not here yet

Terraform/Helm/K8s bootstrap is `kart-infra`'s job, not this repo's (PLATFORM_BLUEPRINT.md S2.4). A
shared `.editorconfig`/analyzer ruleset consumed by multiple services is a natural next addition here
once a second .NET service exists to confirm what's actually shared versus per-service.
