# Provisioned dashboards

Any `*.json` dashboard file dropped in this directory loads automatically on Grafana startup
(provider config: `../dashboards.yaml`) and stays in sync every ~30s. This is the durable half of
dashboard persistence -- `grafana-data` (the Docker volume in `docker-compose.observability.yml`)
survives container restarts/recreates, but not `docker compose down -v`, a wiped Docker install,
or a teammate's fresh clone. A dashboard only actually can't be lost once its JSON is committed to
git here.

## Exporting a dashboard you built in the UI

1. Open the dashboard in Grafana -> dashboard settings (gear icon) -> JSON Model, or use the
   share/export panel's "Export as JSON" option.
2. In the exported JSON, remove the top-level `"id"` field (or set it to `null`) so Grafana treats
   it as a new provisioned dashboard rather than trying to match an internal DB id that won't
   exist on a fresh volume.
3. Save the file here, e.g. `product-service-overview.json`.
4. Commit it. It'll load automatically the next time any Grafana container starts from this repo
   -- your machine, a teammate's, or CI.

`allowUiUpdates: true` in `../dashboards.yaml` means editing a provisioned dashboard in the UI
afterwards is fine day-to-day -- it just won't survive a volume wipe until you re-export and
commit the updated JSON.
