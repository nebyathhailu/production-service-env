from flask import Flask, request, jsonify, g
import requests as http_client
import json
import logging
import signal
import time
import uuid
import os
import sys
from datetime import datetime, timezone

# ── OpenTelemetry setup ───────────────────────────────────────────────────────
from opentelemetry import trace as otel_trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

from prometheus_client import Counter

from metrics import init_metrics

app = Flask(__name__)

# Silence Werkzeug's unstructured access log
logging.getLogger("werkzeug").setLevel(logging.ERROR)

# Configuration
SERVICE_NAME = "expense-api"
PORT = int(os.environ.get("EXPENSE_API_PORT", "3001"))
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
POLICY_SERVICE_URL = os.environ.get("POLICY_SERVICE_URL", "http://policy-service:3002").rstrip("/")
DOWNSTREAM_TIMEOUT = float(os.environ.get("DOWNSTREAM_TIMEOUT", "5"))
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://jaeger:4318")

# Prometheus metrics: request counters/latency histogram + /metrics endpoint.
init_metrics(app, SERVICE_NAME)

# Domain metric: expenses by outcome (approved | rejected | error), by category.
EXPENSES_TOTAL = Counter(
    "expenses_total", "Expenses processed, by category and final outcome.",
    ["category", "status"],
)


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
    # Auto-propagates traceparent on every requests.get/post call
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


def get_request_id():
    return getattr(g, "request_id", None) or request.headers.get("X-Request-ID") or str(uuid.uuid4())


def client_ip():
    xff = request.headers.get("X-Forwarded-For")
    if xff:
        return xff.split(",")[0].strip()
    return request.headers.get("X-Real-IP") or request.remote_addr


def _ms():
    return round((time.time() - g.start_time) * 1000, 2) if hasattr(g, "start_time") else None


def sample_expense():
    """A default expense so GET / bodyless calls (e.g. the load test) still work."""
    return {
        "expense_id": "EXP-" + uuid.uuid4().hex[:6].upper(),
        "employee": "demo",
        "amount": 240.0,
        "category": "travel",
        "currency": "USD",
    }


# ── Request lifecycle hooks ───────────────────────────────────────────────────

@app.before_request
def _start_timer():
    g.start_time = time.time()
    g.request_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())


@app.after_request
def add_request_id_header(resp):
    resp.headers.setdefault("X-Request-ID", get_request_id())
    return resp


# ── 1. Health check — dependency-aware ───────────────────────────────────────
@app.route("/health")
def health():
    rid = get_request_id()
    deps = {}
    overall = "healthy"

    try:
        r = http_client.get(f"{POLICY_SERVICE_URL}/health", timeout=2)
        deps["policy-service"] = "ok" if r.status_code == 200 else "degraded"
    except http_client.RequestException:
        deps["policy-service"] = "unreachable"
        overall = "degraded"

    log("health_check", rid, request.path, 200,
        method=request.method, client_ip=client_ip(), dependencies=deps, duration_ms=_ms())
    return jsonify({
        "service": SERVICE_NAME,
        "status": overall,
        "port": PORT,
        "message": f"{SERVICE_NAME} listening on {PORT}",
        "dependencies": deps,
    }), 200


# ── 2. Submit an expense — starts the flow (expense-api → policy → approval) ──
@app.route("/expenses", methods=["GET", "POST"])
def submit_expense():
    rid = get_request_id()
    expense = request.get_json(silent=True) or sample_expense()
    category = expense.get("category", "unknown")
    log("expense_submitted", rid, request.path, 200, method=request.method,
        client_ip=client_ip(), expense_id=expense.get("expense_id"),
        amount=expense.get("amount"), category=category)

    try:
        # RequestsInstrumentor propagates traceparent automatically
        response = http_client.post(
            f"{POLICY_SERVICE_URL}/validate",
            json=expense,
            headers={"X-Request-ID": rid},
            timeout=DOWNSTREAM_TIMEOUT,
        )
        response.raise_for_status()
        result = response.json()
        status = result.get("status", "unknown")   # approved | rejected
        EXPENSES_TOTAL.labels(category=category, status=status).inc()
        log("expense_decided", rid, request.path, 200, method=request.method,
            expense_id=expense.get("expense_id"), decision=status, duration_ms=_ms())
        return jsonify({
            "request_id": rid,
            "expense_id": expense.get("expense_id"),
            "status": status,
            "detail": result,
        }), 200

    except http_client.RequestException as e:
        EXPENSES_TOTAL.labels(category=category, status="error").inc()
        log("expense_failed", rid, request.path, 502, level="ERROR",
            method=request.method, error=str(e), duration_ms=_ms())
        return jsonify({
            "request_id": rid,
            "expense_id": expense.get("expense_id"),
            "status": "error",
            "message": "Policy service unreachable",
        }), 502


# ── 3. Receive the approval callback from approval-service ────────────────────
@app.route("/expenses/callback", methods=["POST"])
def expense_callback():
    data = request.get_json(silent=True) or {}
    rid = data.get("request_id", get_request_id())
    log("callback_received", rid, request.path, 200,
        source_service=data.get("source_service"),
        expense_id=data.get("expense_id"),
        ledger_ref=data.get("ledger_ref"),
        expense_status=data.get("status"),
        duration_ms=_ms())
    return jsonify({"status": "received"}), 200


# ── 4. Failure simulation endpoints (lab-only) ────────────────────────────────

@app.route("/fail")
def fail():
    rid = get_request_id()
    log("fail_triggered", rid, request.path, 500, level="ERROR",
        method=request.method, duration_ms=_ms())
    return jsonify({
        "request_id": rid,
        "status": "error",
        "message": "Simulated hard failure",
    }), 500


@app.route("/slow")
def slow():
    rid = get_request_id()
    try:
        delay = float(request.args.get("delay", 3))
    except ValueError:
        return jsonify({"request_id": rid, "status": "error",
                        "message": "delay must be a number"}), 400
    delay = max(0.0, min(delay, 30.0))
    log("slow_triggered", rid, request.path, 200, level="WARN",
        method=request.method, delay_s=delay)
    time.sleep(delay)
    log("slow_completed", rid, request.path, 200,
        method=request.method, delay_s=delay, duration_ms=_ms())
    return jsonify({
        "request_id": rid,
        "status": "ok",
        "message": f"Slept {delay}s",
    }), 200


@app.route("/error")
def error():
    rid = get_request_id()
    log("error_triggered", rid, request.path, 500, level="ERROR",
        method=request.method)
    raise RuntimeError("Simulated internal error for observability demo")


@app.route("/dependency-fail")
def dependency_fail():
    rid = get_request_id()
    log("dependency_fail_triggered", rid, request.path, 502, level="ERROR",
        method=request.method, duration_ms=_ms())
    return jsonify({
        "request_id": rid,
        "status": "error",
        "message": "Simulated dependency failure — policy-service reported error",
    }), 502


# ── 5. Error handlers ─────────────────────────────────────────────────────────

@app.errorhandler(404)
def not_found(e):
    rid = get_request_id()
    log("route_not_found", rid, request.path, 404, level="WARN",
        method=request.method, client_ip=client_ip())
    return jsonify({"error": "route not found", "path": request.path}), 404


@app.errorhandler(500)
def internal_error(e):
    rid = get_request_id()
    log("internal_error", rid, request.path, 500, level="ERROR",
        method=request.method, error=str(e))
    return jsonify({"request_id": rid, "status": "error",
                    "message": "Internal server error"}), 500


# ── Shutdown lifecycle ────────────────────────────────────────────────────────

def _handle_shutdown(signum, _frame):
    log("service_stopping", "-", "-", 200, signal=signal.Signals(signum).name)
    sys.exit(0)


# ── Start the server ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _handle_shutdown)
    signal.signal(signal.SIGINT, _handle_shutdown)
    log("service_started", "-", "-", 200,
        bind_host=BIND_HOST, port=PORT, downstream=POLICY_SERVICE_URL,
        otel_endpoint=OTEL_ENDPOINT)
    app.run(host=BIND_HOST, port=PORT, threaded=True)
