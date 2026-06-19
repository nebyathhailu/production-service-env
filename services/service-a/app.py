from flask import Flask, request, jsonify
import requests
import json
import logging
import uuid
from datetime import datetime, timezone

app = Flask(__name__)

# ── structured JSON logger ──────────────────────────────────────────
def log(event, request_id, path, status, extra=None):
    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service": "service-a",
        "event": event,
        "request_id": request_id,
        "path": path,
        "status": status,
    }
    if extra:
        entry.update(extra)
    print(json.dumps(entry), flush=True)


# ── 1. health check ─────────────────────────────────────────────────
@app.route('/health')
def health():
    return jsonify({
        "service": "service-a",
        "status": "healthy",
        "port": 3001,
        "message": "Hello service-a listening on 3001"
    }), 200


# ── 2. start the full request flow ──────────────────────────────────
@app.route('/greet-service-b')
def greet_service_b():
    # generate request_id if not provided
    request_id = request.headers.get('X-Request-ID', str(uuid.uuid4()))

    log("request_received", request_id, "/greet-service-b", 200)

    try:
        # call Service B
        response = requests.get(
            "http://service-b.internal:3002/greet",
            headers={"X-Request-ID": request_id},
            timeout=5
        )
        log("forwarded_to_service_b", request_id, "/greet-service-b", response.status_code)

        return jsonify({
            "request_id": request_id,
            "status": "success",
            "message": "Request completed successfully"
        }), 200

    except requests.exceptions.RequestException as e:
        log("service_b_unreachable", request_id, "/greet-service-b", 500, {"error": str(e)})
        return jsonify({
            "request_id": request_id,
            "status": "error",
            "message": "Service B unreachable"
        }), 500


# ── 3. receive callback from Service C ──────────────────────────────
@app.route('/greeting-rcvd', methods=['POST'])
def greeting_received():
    data = request.get_json()
    request_id = data.get('request_id', 'unknown')

    log("callback_received", request_id, "/greeting-rcvd", 200, {
        "source_service": data.get('source_service'),
        "message": data.get('message')
    })

    return jsonify({"status": "received"}), 200


# ── 4. catch all unknown routes ──────────────────────────────────────
@app.errorhandler(404)
def not_found(e):
    request_id = request.headers.get('X-Request-ID', 'unknown')
    log("route_not_found", request_id, request.path, 404)
    return jsonify({"error": "route not found", "path": request.path}), 404


# ── start the server ─────────────────────────────────────────────────
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3001)
