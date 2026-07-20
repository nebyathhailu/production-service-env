import importlib.util
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import requests

_service_dir = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_service_dir))

# Loaded under a service-specific module name (instead of plain "app") so this
# doesn't collide in sys.modules with ride-api/matching-service's own app.py
# when the full suite runs together.
_spec = importlib.util.spec_from_file_location("dispatch_service_app", _service_dir / "app.py")
dispatch_service = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = dispatch_service
_spec.loader.exec_module(dispatch_service)


def make_client():
    dispatch_service.app.testing = True
    return dispatch_service.app.test_client()


# ── Health ────────────────────────────────────────────────────────────────────

def test_health_returns_200_and_service_metadata():
    client = make_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["service"] == "dispatch-service"
    assert body["status"] == "healthy"


# ── Routing ───────────────────────────────────────────────────────────────────

def test_unknown_route_returns_structured_404():
    client = make_client()
    resp = client.get("/nope")
    assert resp.status_code == 404
    body = resp.get_json()
    assert body["error"] == "route_not_found"


# ── Core flow ─────────────────────────────────────────────────────────────────

def test_assign_driver_sends_callback_to_ride_api():
    client = make_client()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.raise_for_status.return_value = None
    with patch.object(dispatch_service.http_client, "post", return_value=mock_resp):
        resp = client.get("/assign-driver")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "processed"
    assert body["callback_sent"] is True


def test_assign_driver_callback_failure_returns_502():
    client = make_client()
    with patch.object(dispatch_service.http_client, "post",
                      side_effect=requests.exceptions.ConnectionError):
        resp = client.get("/assign-driver")
    assert resp.status_code == 502
    body = resp.get_json()
    assert body["callback_sent"] is False
    assert body["error"] == "callback_failed"


def test_response_echoes_request_id_header():
    client = make_client()
    resp = client.get("/health", headers={"X-Request-ID": "test-rid-789"})
    assert resp.headers["X-Request-ID"] == "test-rid-789"


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
    with patch.object(dispatch_service.time, "sleep") as mock_sleep:
        resp = client.get("/slow")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "ok"
    assert "Slept" in body["message"]
    mock_sleep.assert_called_once_with(3.0)


def test_slow_rejects_non_numeric_delay():
    client = make_client()
    resp = client.get("/slow?delay=abc")
    assert resp.status_code == 400
    assert resp.get_json()["status"] == "error"


def test_slow_caps_delay_at_30_seconds():
    client = make_client()
    with patch.object(dispatch_service.time, "sleep") as mock_sleep:
        resp = client.get("/slow?delay=9999")
    assert resp.status_code == 200
    mock_sleep.assert_called_once_with(30.0)


def test_error_endpoint_triggers_500_handler():
    dispatch_service.app.testing = False
    client = dispatch_service.app.test_client()
    resp = client.get("/error")
    dispatch_service.app.testing = True
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


# ── 500 handler ───────────────────────────────────────────────────────────────

def test_unhandled_exception_returns_500_json():
    dispatch_service.app.testing = False
    client = dispatch_service.app.test_client()
    with patch.object(dispatch_service.http_client, "post",
                      side_effect=RuntimeError("unexpected")):
        resp = client.get("/assign-driver")
    dispatch_service.app.testing = True
    assert resp.status_code == 500
    body = resp.get_json()
    assert body["status"] == "error"
    assert body["message"] == "Internal server error"


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
    client.get("/health")
    body = client.get("/metrics").get_data(as_text=True)
    assert 'http_requests_total{' in body
    assert 'route="/health"' in body
