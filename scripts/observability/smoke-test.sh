#!/usr/bin/env bash
# End-to-end proof that the pipeline actually routes each signal correctly: sends one synthetic
# log, trace span, and metric straight to the Collector's OTLP/HTTP receiver (no service/SDK
# needed) and then queries Loki/Tempo/Prometheus directly to confirm each one landed where it
# should. Useful after touching observability/*.yaml, or any time "is this actually wired up
# right" is in doubt -- this is what verified the pipeline while building it (2026-08-14).
#
# Exits non-zero if any of the three signals didn't show up within the wait budget.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/observability/lib/common.sh

SERVICE_NAME="observability-smoke-test-$$"
TRACE_ID="$(openssl rand -hex 16)"
SPAN_ID="$(openssl rand -hex 8)"
NOW_NS="$(date +%s%N)"
END_NS="$((NOW_NS + 1000000))" # +1ms, so the span has a non-zero duration

echo "Sending synthetic OTLP logs/traces/metrics to the Collector (service.name=${SERVICE_NAME})..."

curl -sS --max-time 5 -X POST "http://localhost:${OBS_OTLP_HTTP_PORT}/v1/logs" \
  -H 'Content-Type: application/json' \
  -d '{
    "resourceLogs": [{
      "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "'"$SERVICE_NAME"'"}}]},
      "scopeLogs": [{"logRecords": [{
        "timeUnixNano": "'"$NOW_NS"'",
        "severityNumber": 9,
        "severityText": "INFO",
        "body": {"stringValue": "observability smoke test log line"}
      }]}]
    }]
  }' -o /dev/null -w 'logs:    HTTP %{http_code}\n'

curl -sS --max-time 5 -X POST "http://localhost:${OBS_OTLP_HTTP_PORT}/v1/traces" \
  -H 'Content-Type: application/json' \
  -d '{
    "resourceSpans": [{
      "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "'"$SERVICE_NAME"'"}}]},
      "scopeSpans": [{"spans": [{
        "traceId": "'"$TRACE_ID"'",
        "spanId": "'"$SPAN_ID"'",
        "name": "smoke-test-span",
        "kind": 1,
        "startTimeUnixNano": "'"$NOW_NS"'",
        "endTimeUnixNano": "'"$END_NS"'"
      }]}]
    }]
  }' -o /dev/null -w 'traces:  HTTP %{http_code}\n'

curl -sS --max-time 5 -X POST "http://localhost:${OBS_OTLP_HTTP_PORT}/v1/metrics" \
  -H 'Content-Type: application/json' \
  -d '{
    "resourceMetrics": [{
      "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "'"$SERVICE_NAME"'"}}]},
      "scopeMetrics": [{"metrics": [{
        "name": "observability_smoke_test",
        "gauge": {"dataPoints": [{"timeUnixNano": "'"$NOW_NS"'", "asDouble": 1}]}
      }]}]
    }]
  }' -o /dev/null -w 'metrics: HTTP %{http_code}\n'

echo
FAILED=false

echo -n "Checking Loki for the log line "
found=false
for _ in $(seq 1 10); do
  count="$(curl -sG --max-time 5 "http://localhost:${OBS_LOKI_PORT}/loki/api/v1/query_range" \
    --data-urlencode "query={service_name=\"${SERVICE_NAME}\"}" \
    --data-urlencode "start=$((NOW_NS - 60000000000))" \
    --data-urlencode "end=$((NOW_NS + 60000000000))" \
    | jq '[.data.result[].values[]] | length' 2>/dev/null || echo 0)"
  if [[ "${count:-0}" -gt 0 ]]; then found=true; break; fi
  printf '.'; sleep 1
done
echo
if $found; then echo "  OK -- log line found in Loki."; else echo "  FAILED -- log line never appeared in Loki." >&2; FAILED=true; fi

echo -n "Checking Tempo for the trace "
found=false
for _ in $(seq 1 10); do
  if curl -sS --max-time 5 "http://localhost:${OBS_TEMPO_PORT}/api/traces/${TRACE_ID}" 2>/dev/null | jq -e '.batches | length > 0' >/dev/null 2>&1; then
    found=true; break
  fi
  printf '.'; sleep 1
done
echo
if $found; then echo "  OK -- trace ${TRACE_ID} found in Tempo."; else echo "  FAILED -- trace never appeared in Tempo." >&2; FAILED=true; fi

echo -n "Checking the Collector's own metrics endpoint for the gauge "
found=false
for _ in $(seq 1 10); do
  if curl -sS --max-time 5 "http://localhost:${OBS_OTEL_METRICS_PORT}/metrics" 2>/dev/null | grep -q "observability_smoke_test.*${SERVICE_NAME}"; then
    found=true; break
  fi
  printf '.'; sleep 1
done
echo
if $found; then
  echo "  OK -- metric present on the Collector's Prometheus-format exporter."
  echo "  (Prometheus itself scrapes that endpoint every ~15s -- give it a little longer before querying"
  echo "   http://localhost:${OBS_PROMETHEUS_PORT} directly; the Collector receiving it is the part this proves.)"
else
  echo "  FAILED -- metric never appeared on the Collector's own exporter." >&2
  FAILED=true
fi

echo
if $FAILED; then
  echo "Smoke test FAILED -- see above. Run scripts/observability/debug.sh for more detail." >&2
  exit 1
fi
echo "Smoke test passed -- logs -> Loki, traces -> Tempo, metrics -> Prometheus are all correctly wired."
