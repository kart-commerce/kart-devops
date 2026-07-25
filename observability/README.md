# Local Observability Stack

The shared local-dev Grafana + Loki + Tempo + Prometheus (+ OpenTelemetry Collector) stack, owned
centrally here per `agent-reusables/docs/standards/observability-standards.md`'s "Local Development"
section. Every `kart-<name>-service` repo's own README should point developers here instead of
copy-pasting a compose file - this is what keeps every service's local telemetry setup identical to
what the shared `observability-standards.md` mandates for the real (Helm-deployed, `kart-infra`-owned)
staging/production stack.

## Usage

From this repo (or from a service repo that has `kart-devops` checked out as a sibling/submodule):

```bash
docker compose -f docker-compose.observability.yml up -d
```

Point your service's OpenTelemetry exporter at the collector - never at Loki/Tempo directly:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317   # gRPC
# or
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # HTTP/protobuf
```

Serilog's console (JSON) sink output is expected to be shipped to the Collector's OTLP log receiver
the same way (an OTLP log exporter/appender, or the OpenTelemetry Collector's own log-file/console
receiver in each service's own Docker Compose dev setup) - the shipping mechanism is an infra concern
per the standards doc, not restated here.

## Exposed Ports

| Service | Port | Purpose |
|---|---|---|
| Grafana | `3000` | UI - http://localhost:3000. Default login: **admin / admin** (Grafana will prompt to change it on first login; safe to skip for local dev). |
| Loki | `3100` | Log push/query API. Also accepts logs natively via OTLP at `/otlp/v1/logs`. Not normally browsed directly - use Grafana's Explore view instead. |
| Tempo | `3200` | Trace query API, used by Grafana's Tempo datasource. |
| Prometheus | `9090` | Metrics UI/API - http://localhost:9090. |
| OTel Collector | `4317` (gRPC) / `4318` (HTTP) | OTLP ingest - point every service's `OTEL_EXPORTER_OTLP_ENDPOINT` here. |
| OTel Collector | `8889` | Prometheus-format metrics exporter, scraped by the `prometheus` service above. |

## What's provisioned already

- Grafana's Prometheus/Loki/Tempo datasources are pre-provisioned (`grafana/provisioning/datasources/`)
  with trace-to-logs and service-map correlation wired up, so a developer opens Grafana and can
  immediately pivot log -> trace -> metric via the shared trace id, with no manual datasource setup.
- The OTel Collector fans one OTLP ingest point out to Loki (logs), Tempo (traces), and a
  Prometheus-scrapable exporter (metrics) - see `otel-collector-config.yaml`.

## What's not here

This is the **local development** stack only, intentionally minimal-config (filesystem/local storage,
no auth hardening, no retention tuning, no HA). The real Helm-deployed LGTM stack for
staging/production is `kart-infra`'s job (PLATFORM_BLUEPRINT.md S2.4), with its own Terraform/Helm
config, retention policy, and alerting - not this file.
