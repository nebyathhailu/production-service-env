import importlib.util
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import requests

_service_dir = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_service_dir))

# Loaded under a service-specific module name (instead of plain "app") so this
# doesn't collide in sys.modules with matching-service/dispatch-service's own
# app.py when the full suite runs together.
_spec = importlib.util.spec_from_file_location("ride_api_app", _service_dir / "app.py")
ride_api = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = ride_api
_spec.loader.exec_module(ride_api)


def make_client():
    ride_api.app.testing = True
    return ride_api.app.test_client()


# ── Health ────────────────────────────────────────────────────────────────────

def test_health_returns_200_and_service_metadata():
    client = make_client()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    with patch.object(ride_api.http_client, "get", return_value=mock_resp):
        resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["service"] == "ride-api"
    assert body["status"] == "healthy"
    assert body["dependencies"]["matching-service"] == "ok"


def test_health_degraded_when_matching_service_unreachable():
    client = make_client()
    with patch.object(ride_api.http_client, "get",
                      side_effect=requests.exceptions.ConnectionError):
        resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "degraded"
    assert body["dependencies"]["matching-service"] == "unreachable"


# ── Routing ───────────────────────────────────────────────────────────────────

def test_unknown_route_returns_structured_404():
    client = make_client()
    resp = client.get("/nope")
    assert resp.status_code == 404
    body = resp.get_json()
    assert body["error"] == "route not found"


# ── Core flow ─────────────────────────────────────────────────────────────────

def test_request_ride_success():
    client = make_client()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.raise_for_status.return_value = None
    with patch.object(ride_api.http_client, "get", return_value=mock_resp):
        resp = client.get("/request-ride")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "success"


def test_request_ride_downstream_failure_returns_502():
    client = make_client()
    with patch.object(ride_api.http_client, "get",
                      side_effect=requests.exceptions.ConnectionError):
        resp = client.get("/request-ride")
    assert resp.status_code == 502
    body = resp.get_json()
    assert body["status"] == "error"


def test_driver_assigned_callback():
    client = make_client()
    resp = client.post(
        "/driver-assigned",
        json={"request_id": "abc", "source_service": "dispatch-service"},
    )
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "received"


def test_response_echoes_request_id_header():
    client = make_client()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    with patch.object(ride_api.http_client, "get", return_value=mock_resp):
        resp = client.get("/health", headers={"X-Request-ID": "test-rid-123"})
    assert resp.headers["X-Request-ID"] == "test-rid-123"


# ── Failure simulation endpoints ──────────────────────────────────────────────

def test_fail_returns_500_json():
    client = make_client()
    resp = client.get("/fail")
    assert resp.status_code == 500
    body = resp.get_json()
    assert body["status"] == "error"
    assert body["message"] == "Simulated hard failure"
    assert "request_id" in body


def test_slow_returns_200_with_default_delay():
    client = make_client()
    with patch.object(ride_api.time, "sleep") as mock_sleep:
        resp = client.get("/slow")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "ok"
    assert "Slept" in body["message"]
    mock_sleep.assert_called_once_with(3.0)


def test_slow_accepts_custom_delay():
    client = make_client()
    with patch.object(ride_api.time, "sleep") as mock_sleep:
        resp = client.get("/slow?delay=5")
    assert resp.status_code == 200
    mock_sleep.assert_called_once_with(5.0)


def test_slow_rejects_non_numeric_delay():
    client = make_client()
    resp = client.get("/slow?delay=abc")
    assert resp.status_code == 400
    body = resp.get_json()
    assert body["status"] == "error"


def test_slow_caps_delay_at_30_seconds():
    client = make_client()
    with patch.object(ride_api.time, "sleep") as mock_sleep:
        resp = client.get("/slow?delay=9999")
    assert resp.status_code == 200
    mock_sleep.assert_called_once_with(30.0)


def test_error_endpoint_triggers_500_handler():
    ride_api.app.testing = False
    client = ride_api.app.test_client()
    resp = client.get("/error")
    ride_api.app.testing = True
    assert resp.status_code == 500
    body = resp.get_json()
    assert body["status"] == "error"
    assert body["message"] == "Internal server error"


def test_dependency_fail_returns_502_json():
    client = make_client()
    resp = client.get("/dependency-fail")
    assert resp.status_code == 502
    body = resp.get_json()
    assert body["status"] == "error"
    assert "dependency" in body["message"].lower()
    assert "request_id" in body


# ── Prometheus metrics ────────────────────────────────────────────────────────

def test_metrics_endpoint_exposes_prometheus():
    client = make_client()
    resp = client.get("/metrics")
    assert resp.status_code == 200
    body = resp.get_data(as_text=True)
    assert "http_requests_total" in body
    assert "service_up" in body


def test_request_is_counted_by_route():
    client = make_client()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    with patch.object(ride_api.http_client, "get", return_value=mock_resp):
        client.get("/health")
    body = client.get("/metrics").get_data(as_text=True)
    assert 'http_requests_total{' in body
    assert 'route="/health"' in body
