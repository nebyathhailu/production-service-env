from flask import Flask, jsonify, request
import json
import logging
import os
import signal
import sys
import uuid
from datetime import datetime, timezone

import requests

# Silence Werkzeug's unstructured access log; we emit our own structured JSON.
logging.getLogger("werkzeug").setLevel(logging.ERROR)

# Configuration (overridable via environment variables for systemd/deployment).
SERVICE_NAME = "service-c"
PORT = int(os.environ.get("SERVICE_C_PORT", "3003"))
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
SERVICE_A_URL = os.environ.get("SERVICE_A_URL", "http://service-a.internal:3001").rstrip("/")
DOWNSTREAM_TIMEOUT = float(os.environ.get("DOWNSTREAM_TIMEOUT", "5"))

app = Flask(__name__)


def iso_now():
    """Current UTC time as an ISO-8601 string with a trailing Z."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(event, request_id, path, status, **extra):
    """Emit one structured JSON log line to stdout (captured by journald)."""
    entry = {
        "timestamp": iso_now(),
        "service": SERVICE_NAME,
        "event": event,
        "request_id": request_id,
        "path": path,
        "status": status,
    }
    entry.update(extra)
    sys.stdout.write(json.dumps(entry) + "\n")
    sys.stdout.flush()


def request_id():
    """Use the incoming X-Request-ID, or mint one so the trace never breaks."""
    return request.headers.get("X-Request-ID") or str(uuid.uuid4())


def client_ip():
    """Real caller IP: X-Forwarded-For/X-Real-IP if set, else the socket peer."""
    xff = request.headers.get("X-Forwarded-For")
    if xff:
        return xff.split(",")[0].strip()
    return request.headers.get("X-Real-IP") or request.remote_addr


# Health check endpoint for liveness probes and validation commands.
@app.get("/health")
def health():
    rid = request_id()
    log("health_check", rid, request.path, 200, method=request.method, client_ip=client_ip())
    return jsonify(
        service=SERVICE_NAME,
        status="healthy",
        port=PORT,
        message=f"Hello {SERVICE_NAME} listening on {PORT}",
    ), 200


# Receive a request from Service B, then notify Service A via its callback endpoint.
@app.get("/greet-c")
def greet_c():
    rid = request_id()
    log("request_received", rid, request.path, 200, method=request.method, client_ip=client_ip())
    callback_url = f"{SERVICE_A_URL}/greeting-rcvd"
    payload = {
        "request_id": rid,
        "source_service": SERVICE_NAME,
        "message": "Greeting processed",
        "timestamp": iso_now(),
    }
    try:
        resp = requests.post(
            callback_url,
            json=payload,
            headers={"X-Request-ID": rid},
            timeout=DOWNSTREAM_TIMEOUT,
        )
        resp.raise_for_status()
        log("callback_sent", rid, request.path, 200, method=request.method,
            target="service-a", downstream_status=resp.status_code)
        return jsonify(request_id=rid, status="processed", callback_sent=True), 200
    except requests.RequestException as e:
        log("request_failed", rid, request.path, 502, method=request.method,
            target="service-a", error="callback_failed", detail=str(e))
        return jsonify(request_id=rid, status="error", callback_sent=False,
                       error="callback_failed"), 502


# Unknown routes return 404 with a structured log entry for troubleshooting.
@app.errorhandler(404)
def not_found(_e):
    rid = request_id()
    log("route_not_found", rid, request.path, 404, method=request.method, client_ip=client_ip())
    return jsonify(request_id=rid, status="error", error="route_not_found",
                   path=request.path), 404


@app.after_request
def add_request_id_header(resp):
    """Echo the trace id back on every response."""
    resp.headers.setdefault("X-Request-ID", request_id())
    return resp


# systemd sends SIGTERM on `systemctl stop`; log a structured shutdown event.
def _handle_shutdown(signum, _frame):
    log("service_stopping", "-", "-", 200, signal=signal.Signals(signum).name)
    sys.exit(0)


# Entry point: start the threaded server on the configured host/port.
if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _handle_shutdown)
    signal.signal(signal.SIGINT, _handle_shutdown)
    log("service_started", "-", "-", 200,
        bind_host=BIND_HOST, port=PORT, callback=SERVICE_A_URL)
    app.run(host=BIND_HOST, port=PORT, threaded=True)
