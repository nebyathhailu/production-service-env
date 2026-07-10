# Benchmark Report

This report documents the system's behavior under normal, stress, and controlled-failure
traffic, per the Observability Implementation Lab requirements. Numbers below are placeholders —
replace them with real output once the instrumentation (Prometheus metrics, Jaeger tracing) lands
and `scripts/load-test.js` is run against the full stack.

## Test tool used

[k6](https://k6.io/) — chosen for scriptable multi-scenario load definitions in a single file and
built-in threshold/check reporting.

## Test command

```bash
# All three scenarios back-to-back:
k6 run scripts/load-test.js

# Or one at a time:
k6 run -e SCENARIO=normal  scripts/load-test.js
k6 run -e SCENARIO=stress  scripts/load-test.js
k6 run -e SCENARIO=failure scripts/load-test.js
```

## Results

| Scenario | Requests | Concurrency | Avg Latency | p95 Latency | Error Rate | Alert Triggered |
|---|---|---|---|---|---|---|
| Normal traffic | TBD | 10 | TBD | TBD | TBD | None expected |
| Stress traffic | TBD | 50 | TBD | TBD | TBD | HighLatency (expected) |
| Failure traffic | TBD | 10 | TBD | TBD | TBD | HighErrorRate (expected) |

## Metrics observed

_Fill in after running against the live stack — e.g. `http_requests_total`, `http_errors_total`,
and `http_request_duration_seconds` values pulled from the Grafana dashboard
(`grafana/dashboards/service-env-overview.json`) during each scenario._

## Alerts triggered

_Document which Prometheus alerts (see `alert-rules.yml`) fired during each scenario, with
timestamps and the PromQL query result that caused them to fire._

## Traces observed

_Paste or screenshot a Jaeger trace captured during the failure scenario, showing the span where
the failure/latency actually occurred (service name, endpoint, duration, error state)._

## Lessons learned

_Fill in once the full loop (load test -> metrics -> alert -> trace -> log) has actually been run
end to end. Note anything that required tuning (alert thresholds, k6 VUs/duration, etc.)._
