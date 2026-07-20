"""Prometheus metrics instrumentation (MELT: Metrics).

Exposes a /metrics endpoint and records, for every request:
  - http_requests_total            (counter)   service, method, route, status_code
  - http_request_duration_seconds  (histogram) service, method, route
  - http_errors_total              (counter)   service, method, route, status_code  (5xx)
  - service_up                     (gauge)     service

Kept in its own module so it layers onto app.py with a single init_metrics()
call, independent of the logging/tracing instrumentation.
"""
import time

from flask import Response, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests.",
    ["service", "method", "route", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["service", "method", "route"],
)
ERROR_COUNT = Counter(
    "http_errors_total",
    "Total HTTP responses with a 5xx status.",
    ["service", "method", "route", "status_code"],
)
SERVICE_UP = Gauge(
    "service_up",
    "1 while the service process is running.",
    ["service"],
)


def init_metrics(app, service_name):
    """Attach request metrics and a /metrics endpoint to a Flask app."""
    SERVICE_UP.labels(service=service_name).set(1)

    @app.before_request
    def _start_timer():
        request._metrics_start = time.perf_counter()

    @app.after_request
    def _record_metrics(response):
        # Label on the matched route rule (not the raw path) so unknown paths and
        # probes can't explode metric cardinality.
        route = request.url_rule.rule if request.url_rule else "<unmatched>"
        status = str(response.status_code)
        REQUEST_COUNT.labels(service_name, request.method, route, status).inc()
        start = getattr(request, "_metrics_start", None)
        if start is not None:
            REQUEST_LATENCY.labels(service_name, request.method, route).observe(
                time.perf_counter() - start
            )
        if response.status_code >= 500:
            ERROR_COUNT.labels(service_name, request.method, route, status).inc()
        return response

    @app.get("/metrics")
    def metrics():
        return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)
