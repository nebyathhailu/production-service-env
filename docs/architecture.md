# Observability Architecture

## Service architecture

Same request-flow backbone as the base containerized lab, with an observability layer added
alongside it. Every application container emits metrics, logs, and traces; nothing about the
public request path changes.

```
Client / Load Test Tool (k6)
        |
        v
    Nginx (:8080, only published host port)
        |
        v
    ride-api (:3001) ---> matching-service (:3002) ---> dispatch-service (:3003)
        ^                                                       |
        +-------------------------------------------------------+
                        (callback to ride-api)
```

## Request flow

1. Client (or `scripts/load-test.js`) hits Nginx on `:8080`.
2. Nginx proxies to ride-api only — matching-service and dispatch-service are never directly
   reachable from outside the Compose network (no `ports:` published for them).
3. ride-api calls matching-service, which calls dispatch-service, which calls back to ride-api —
   identical to the base lab's ride-api -> matching-service -> dispatch-service -> ride-api chain.
4. Every hop carries `X-Request-ID` end to end for correlation.

## Telemetry flow

```
 ride-api/matching-service/dispatch-service
   |      |      |
   | metrics      |
   +------+-------+---> Prometheus (:9090, scrapes /metrics on each service every 5s)
   |      |      |                        |
   | traces       |                       v
   +------+-------+---> Jaeger (:16686, OTLP receiver on :4318)     Grafana (:3000)
   |      |      |                        ^                        (Prometheus as
   | logs         |                       |                         data source)
   +------+-------+---> docker compose logs <service>   <----------------+
```

- **Metrics collection flow**: each service exposes `/metrics` in Prometheus text format
  (`http_requests_total`, `http_request_duration_seconds`, `http_errors_total`, `service_up`,
  labeled by `service`/`method`/`route`/`status_code`). Prometheus (`prometheus.yml`) scrapes all
  three by Compose service name on a 5s interval and evaluates `alert-rules.yml` against them.
- **Tracing flow**: each service emits an OpenTelemetry span per incoming request, and propagates
  trace context on every outbound call (ride-api->matching-service, matching-service->dispatch-service,
  dispatch-service->ride-api callback), so one client request produces one connected trace visible
  in Jaeger as `gateway -> ride-api -> matching-service -> dispatch-service`.
- **Logging flow**: unchanged from the base lab's structured JSON logging (`request_id`,
  `service`, `event`, `status`), extended with `trace_id`, `level`, and `duration_ms` so a log line
  can be cross-referenced with its Jaeger trace and Prometheus histogram bucket.
- **Alerting flow**: Prometheus evaluates the three rules in `alert-rules.yml` continuously;
  firing alerts are visible both in Prometheus's own Alerts page and in the Grafana dashboard's
  "Alert State" panel.

## Known limitations

- Nginx itself is not instrumented with `/metrics` or trace spans in this iteration — only the
  three application services are. Nginx's own access logs (JSON-formatted, per the base lab) are
  the only signal at the gateway layer.
- No Alertmanager/Slack/Discord notification wiring — alerts are visible in Prometheus/Grafana
  but do not page anyone. Documented as an optional enhancement per the PRD.
- No Loki/Promtail — logs are viewed via `docker compose logs <service>`, which the PRD accepts as
  the minimum acceptable log-access method.
