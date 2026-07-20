from flask import Flask, jsonify, request, g
import json
import logging
import signal
import time
import os
import sys
import uuid
from datetime import datetime, timezone

import requests as http_client

# ── OpenTelemetry setup ───────────────────────────────────────────────────────
from opentelemetry import trace as otel_trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

from metrics import init_metrics

# Silence Werkzeug's unstructured access log; we emit our own structured JSON.
logging.getLogger("werkzeug").setLevel(logging.ERROR)

# Configuration
SERVICE_NAME = "matching-service"
PORT = int(os.environ.get("MATCHING_SERVICE_PORT", "3002"))
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
DISPATCH_SERVICE_URL = os.environ.get("DISPATCH_SERVICE_URL", "http://dispatch-service.internal:3003").rstrip("/")
DOWNSTREAM_TIMEOUT = float(os.environ.get("DOWNSTREAM_TIMEOUT", "5"))
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://jaeger:4318")

app = Flask(__name__)

# Prometheus metrics: request counters/latency histogram + /metrics endpoint.
init_metrics(app, SERVICE_NAME)


def _setup_tracing():
    if "pytest" in sys.modules:
        return
    resource = Resource(attributes={"service.name": SERVICE_NAME})
    provider = TracerProvider(resource=resource)
    _base = OTEL_ENDPOINT.rstrip("/")
    if _base.endswith("/v1/traces"):
        _base = _base[: -len("/v1/traces")]
    exporter = OTLPSpanExporter(endpoint=f"{_base}/v1/traces")
    provider.add_span_processor(BatchSpanProcessor(exporter))
    otel_trace.set_tracer_provider(provider)
    FlaskInstrumentor().instrument_app(app)
    RequestsInstrumentor().instrument()


_setup_tracing()


# ── Helpers ───────────────────────────────────────────────────────────────────

def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _trace_id():
    span = otel_trace.get_current_span()
    ctx = span.get_span_context()
    if ctx and ctx.is_valid:
        return format(ctx.trace_id, "032x")
    return None


def log(event, request_id, path, status, level="INFO", **extra):
    entry = {
        "timestamp": iso_now(),
        "service": SERVICE_NAME,
        "level": level,
        "event": event,
        "request_id": request_id,
        "path": path,
        "status": status,
    }
    tid = _trace_id()
    if tid:
        entry["trace_id"] = tid
    entry.update(extra)
    sys.stdout.write(json.dumps(entry) + "\n")
    sys.stdout.flush()


def request_id():
    return getattr(g, "request_id", None) or request.headers.get("X-Request-ID") or str(uuid.uuid4())


def client_ip():
    xff = request.headers.get("X-Forwarded-For")
    if xff:
        return xff.split(",")[0].strip()
    return request.headers.get("X-Real-IP") or request.remote_addr


def _ms():
    return round((time.time() - g.start_time) * 1000, 2) if hasattr(g, "start_time") else None


# ── Request lifecycle hooks ───────────────────────────────────────────────────

@app.before_request
def _start_timer():
    g.start_time = time.time()
    g.request_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())


@app.after_request
def add_request_id_header(resp):
    resp.headers.setdefault("X-Request-ID", request_id())
    return resp


# ── Health check — dependency-aware ──────────────────────────────────────────
@app.get("/health")
def health():
    rid = request_id()
    deps = {}
    overall = "healthy"

    try:
        r = http_client.get(f"{DISPATCH_SERVICE_URL}/health", timeout=2)
        deps["dispatch-service"] = "ok" if r.status_code == 200 else "degraded"
    except http_client.RequestException:
        deps["dispatch-service"] = "unreachable"
        overall = "degraded"

    log("health_check", rid, request.path, 200,
        method=request.method, client_ip=client_ip(), dependencies=deps, duration_ms=_ms())
    return jsonify(
        service=SERVICE_NAME,
        status=overall,
        port=PORT,
        message=f"Hello {SERVICE_NAME} listening on {PORT}",
        dependencies=deps,
    ), 200


# ── Receive from ride-api, forward to dispatch-service ───────────────────────
@app.get("/find-driver")
def find_driver():
    rid = request_id()
    log("request_received", rid, request.path, 200,
        method=request.method, client_ip=client_ip())

    try:
        # RequestsInstrumentor propagates traceparent header automatically
        resp = http_client.get(
            f"{DISPATCH_SERVICE_URL}/assign-driver",
            headers={"X-Request-ID": rid},
            timeout=DOWNSTREAM_TIMEOUT,
        )
        resp.raise_for_status()
        log("request_forwarded", rid, request.path, 200,
            method=request.method, target="dispatch-service",
            downstream_status=resp.status_code, duration_ms=_ms())
        return jsonify(request_id=rid, status="forwarded", target="dispatch-service"), 200

    except http_client.HTTPError as e:
        log("request_failed", rid, request.path, 502, level="ERROR",
            method=request.method, target="dispatch-service",
            error=f"downstream_http_{e.response.status_code}", duration_ms=_ms())
        return jsonify(request_id=rid, status="error", error="downstream_error"), 502

    except http_client.RequestException as e:
        log("request_failed", rid, request.path, 502, level="ERROR",
            method=request.method, target="dispatch-service",
            error="downstream_unreachable", detail=str(e), duration_ms=_ms())
        return jsonify(request_id=rid, status="error", error="downstream_unreachable"), 502


# ── Failure simulation endpoints (lab-only) ───────────────────────────────────

@app.route("/fail")
def fail():
    rid = request_id()
    log("fail_triggered", rid, request.path, 500, level="ERROR",
        method=request.method, duration_ms=_ms())
    return jsonify(request_id=rid, status="error",
                   message="Simulated hard failure"), 500


@app.route("/slow")
def slow():
    rid = request_id()
    try:
        delay = float(request.args.get("delay", 3))
    except ValueError:
        return jsonify(request_id=rid, status="error",
                       message="delay must be a number"), 400
    delay = max(0.0, min(delay, 30.0))
    log("slow_triggered", rid, request.path, 200, level="WARN",
        method=request.method, delay_s=delay)
    time.sleep(delay)
    log("slow_completed", rid, request.path, 200,
        method=request.method, delay_s=delay, duration_ms=_ms())
    return jsonify(request_id=rid, status="ok",
                   message=f"Slept {delay}s"), 200


@app.route("/error")
def error():
    rid = request_id()
    log("error_triggered", rid, request.path, 500, level="ERROR",
        method=request.method)
    raise RuntimeError("Simulated internal error for observability demo")


@app.route("/dependency-fail")
def dependency_fail():
    rid = request_id()
    log("dependency_fail_triggered", rid, request.path, 502, level="ERROR",
        method=request.method, duration_ms=_ms())
    return jsonify(request_id=rid, status="error",
                   message="Simulated dependency failure — dispatch-service reported error"), 502


# ── Error handlers ────────────────────────────────────────────────────────────

@app.errorhandler(404)
def not_found(_e):
    rid = request_id()
    log("route_not_found", rid, request.path, 404, level="WARN",
        method=request.method, client_ip=client_ip())
    return jsonify(request_id=rid, status="error", error="route_not_found",
                   path=request.path), 404


@app.errorhandler(500)
def internal_error(e):
    rid = request_id()
    log("internal_error", rid, request.path, 500, level="ERROR",
        method=request.method, error=str(e))
    return jsonify(request_id=rid, status="error",
                   message="Internal server error"), 500


# ── Shutdown lifecycle ────────────────────────────────────────────────────────

def _handle_shutdown(signum, _frame):
    log("service_stopping", "-", "-", 200, signal=signal.Signals(signum).name)
    sys.exit(0)


# ── Start the server ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _handle_shutdown)
    signal.signal(signal.SIGINT, _handle_shutdown)
    log("service_started", "-", "-", 200,
        bind_host=BIND_HOST, port=PORT, downstream=DISPATCH_SERVICE_URL,
        otel_endpoint=OTEL_ENDPOINT)
    app.run(host=BIND_HOST, port=PORT, threaded=True)
