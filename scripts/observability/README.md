# scripts/observability/

Lifecycle and diagnostic scripts for the shared local-dev observability stack (Grafana + Loki +
Tempo + Prometheus + an OpenTelemetry Collector -- see `../../docker-compose.observability.yml`
and `../../observability/README.md` for the stack itself). These scripts only manage that stack;
they never touch the main platform stack's 18 business-service containers.

| Script | What it does |
|---|---|
| `up.sh` | Starts the stack and waits (default 60s, `--timeout N` to change) for every component to report healthy. Idempotent -- safe to re-run. `--no-wait` starts and returns immediately. |
| `down.sh` | Stops the stack. Pass `-v` to also wipe its data volumes (Loki chunks, Tempo blocks, Prometheus TSDB, Grafana's db) for a clean-slate restart. |
| `restart.sh` | Restarts in place (`docker compose restart` -- picks up an edited `observability/*.yaml` config, since those are read on container start). `--recreate` does a full down+up instead (needed after editing `docker-compose.observability.yml` itself, e.g. a new port mapping). |
| `status.sh` | One-shot health snapshot, no waiting. Exits non-zero if anything isn't healthy -- usable as a gate in other scripts. |
| `logs.sh [component]` | Tails logs for the whole stack, or one component (`loki`, `tempo`, `prometheus`, `otel-collector`, `grafana`). |
| `debug.sh [--logs-only]` | Full diagnostic report: container/health status, which process holds each port, a check for the historical "Tempo OTLP receiver never started" config bug, Grafana's own view of each datasource's health, and recent logs. `--logs-only` skips straight to logs for whichever components aren't healthy. |
| `smoke-test.sh` | Sends one synthetic log/trace/metric straight to the Collector's OTLP/HTTP receiver (no service or SDK needed) and confirms each one actually landed in Loki/Tempo/Prometheus respectively. The fastest way to prove "is the pipeline actually wired up right" after touching any config here. |

`lib/common.sh` holds the shared container list, health-check URLs, and polling logic every
script above uses -- sourced, not run directly.

## `../dev-up.sh`'s pre-flight check

`scripts/dev-up.sh` runs `up.sh` before starting the main stack, and aborts if the observability
stack doesn't become healthy -- every backend service points its OTLP exporter at the Collector
unconditionally, so a service booting before the Collector exists just means its logs/traces/
metrics silently go nowhere until someone notices Grafana is empty. Bypass with
`SKIP_OBSERVABILITY_CHECK=1 scripts/dev-up.sh` if you deliberately don't want it running (e.g. a
memory-constrained machine).

## Why this stack has its own `name:` in the compose file

`docker-compose.observability.yml` declares `name: kart-observability` at the top level. Without
it, Compose infers a project name from the current directory -- which, run from this repo's own
root (exactly what these scripts do), collides with `docker-compose.yml`'s own inferred project
name (`kart-devops`). `docker compose down` tears down its entire *inferred project*, not just
the services listed in whichever file you pointed it at -- so before this fix, running this
stack's `down.sh` from this directory silently took the entire main stack (all 18 business
services + Postgres/Mongo/Redis/RabbitMQ/OpenSearch) down with it too. Confirmed the hard way
while building these scripts (2026-08-14): data volumes survived (`down` without `-v` never
touches them), but every container needed to be recreated. If you ever see a *different* compose
file elsewhere in this repo start behaving like it shares state with another stack, this is the
first thing to check.
