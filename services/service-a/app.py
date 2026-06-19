from flask import Flask, request, jsonify
import requests
import json
import logging
import uuid
import os
import sys
from datetime import datetime, timezone

app = Flask(__name__)

# Silence Werkzeug's unstructured access log
logging.getLogger("werkzeug").setLevel(logging.ERROR)

# Configuration
SERVICE_NAME = "service-a"
PORT = int(os.environ.get("SERVICE_A_PORT", "3001"))
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
SERVICE_B_URL = os.environ.get("SERVICE_B_URL", "http://service-b.internal:3002").rstrip("/")
DOWNSTREAM_TIMEOUT = float(os.environ.get("DOWNSTREAM_TIMEOUT", "5"))


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(event, request_id, path, status, **extra):
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


def get_request_id():
    return request.headers.get("X-Request-ID") or str(uuid.uuid4())


# ── 1. health check ──────────────────────────────────────────────────
@app.route('/health')
def health():
    rid = get_request_id()
    log("health_check", rid, request.path, 200, method=request.method)
    return jsonify({
        "service": SERVICE_NAME,
        "status": "healthy",
        "port": PORT,
        "message": f"Hello {SERVICE_NAME} listening on {PORT}"
    }), 200


# ── 2. start the full request flow ───────────────────────────────────
@app.route('/greet-service-b')
def greet_service_b():
    rid = get_request_id()
    log("request_received", rid, request.path, 200, method=request.method)

    try:
        response = requests.get(
            f"{SERVICE_B_URL}/greet",
            headers={"X-Request-ID": rid},
            timeout=DOWNSTREAM_TIMEOUT
        )
        response.raise_for_status()
        log("request_forwarded", rid, request.path,
            response.status_code, method=request.method, target="service-b")

        return jsonify({
            "request_id": rid,
            "status": "success",
            "message": "Request completed successfully"
        }), 200

    except requests.exceptions.RequestException as e:
        log("request_failed", rid, request.path, 502,
            method=request.method, error=str(e))
        return jsonify({
            "request_id": rid,
            "status": "error",
            "message": "Service B unreachable"
        }), 502


# ── 3. receive callback from Service C ───────────────────────────────
@app.route('/greeting-rcvd', methods=['POST'])
def greeting_received():
    data = request.get_json(silent=True) or {}
    rid = data.get('request_id', 'unknown')

    log("callback_received", rid, request.path, 200,
        source_service=data.get('source_service'),
        message=data.get('message'))

    return jsonify({"status": "received"}), 200


# ── 4. catch all unknown routes ──────────────────────────────────────
@app.errorhandler(404)
def not_found(e):
    rid = get_request_id()
    log("route_not_found", rid, request.path, 404, method=request.method)
    return jsonify({"error": "route not found", "path": request.path}), 404


# ── echo request ID on every response ────────────────────────────────
@app.after_request
def add_request_id_header(resp):
    resp.headers.setdefault("X-Request-ID", get_request_id())
    return resp


# ── start the server ─────────────────────────────────────────────────
if __name__ == '__main__':
    log("service_started", "-", "-", 200,
        bind_host=BIND_HOST, port=PORT, downstream=SERVICE_B_URL)
    app.run(host=BIND_HOST, port=PORT, threaded=True)