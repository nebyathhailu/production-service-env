import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app as service_c  # noqa: E402


def make_client():
    service_c.app.testing = True
    return service_c.app.test_client()


# ── Health ────────────────────────────────────────────────────────────────────

def test_health_returns_200_and_service_metadata():
    client = make_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["service"] == "service-c"
    assert body["status"] == "healthy"


# ── Routing ───────────────────────────────────────────────────────────────────

def test_unknown_route_returns_structured_404():
    client = make_client()
    resp = client.get("/nope")
    assert resp.status_code == 404
    body = resp.get_json()
    assert body["error"] == "route_not_found"


# ── Core flow ─────────────────────────────────────────────────────────────────

def test_greet_c_sends_callback_to_service_a():
    client = make_client()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.raise_for_status.return_value = None
    with patch.object(service_c.http_client, "post", return_value=mock_resp):
        resp = client.get("/greet-c")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "processed"
    assert body["callback_sent"] is True


def test_greet_c_callback_failure_returns_502():
    client = make_client()
    with patch.object(service_c.http_client, "post",
                      side_effect=requests.exceptions.ConnectionError):
        resp = client.get("/greet-c")
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
    with patch.object(service_c.time, "sleep") as mock_sleep:
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
    with patch.object(service_c.time, "sleep") as mock_sleep:
        resp = client.get("/slow?delay=9999")
    assert resp.status_code == 200
    mock_sleep.assert_called_once_with(30.0)


def test_error_endpoint_triggers_500_handler():
    service_c.app.testing = False
    client = service_c.app.test_client()
    resp = client.get("/error")
    service_c.app.testing = True
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
    service_c.app.testing = False
    client = service_c.app.test_client()
    with patch.object(service_c.http_client, "post",
                      side_effect=RuntimeError("unexpected")):
        resp = client.get("/greet-c")
    service_c.app.testing = True
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
