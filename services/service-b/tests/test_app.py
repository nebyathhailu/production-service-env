import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app as policy_service  # noqa: E402


def make_client():
    policy_service.app.testing = True
    return policy_service.app.test_client()


# ── Health ────────────────────────────────────────────────────────────────────

def test_health_returns_200_and_service_metadata():
    client = make_client()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    with patch.object(policy_service.http_client, "get", return_value=mock_resp):
        resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["service"] == "policy-service"
    assert body["status"] == "healthy"
    assert body["dependencies"]["approval-service"] == "ok"


def test_health_degraded_when_approval_service_unreachable():
    client = make_client()
    with patch.object(policy_service.http_client, "get",
                      side_effect=requests.exceptions.ConnectionError):
        resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "degraded"
    assert body["dependencies"]["approval-service"] == "unreachable"


# ── Routing ───────────────────────────────────────────────────────────────────

def test_unknown_route_returns_structured_404():
    client = make_client()
    resp = client.get("/nope")
    assert resp.status_code == 404
    body = resp.get_json()
    assert body["error"] == "route_not_found"


# ── Core flow: validate against policy ────────────────────────────────────────

def test_validate_within_policy_forwards_to_approval():
    client = make_client()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.raise_for_status.return_value = None
    mock_resp.json.return_value = {"status": "approved", "ledger_ref": "LED-2"}
    with patch.object(policy_service.http_client, "post", return_value=mock_resp):
        resp = client.post("/validate", json={"expense_id": "EXP-1",
                                              "amount": 100, "category": "travel"})
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "approved"


def test_validate_over_limit_is_rejected_without_calling_approval():
    client = make_client()
    with patch.object(policy_service.http_client, "post") as mock_post:
        resp = client.post("/validate", json={"expense_id": "EXP-2",
                                              "amount": 9999, "category": "travel"})
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "rejected"
    assert body["policy_check"] == "failed"
    mock_post.assert_not_called()


def test_validate_bad_category_is_rejected():
    client = make_client()
    with patch.object(policy_service.http_client, "post") as mock_post:
        resp = client.post("/validate", json={"expense_id": "EXP-3",
                                              "amount": 10, "category": "gambling"})
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "rejected"
    mock_post.assert_not_called()


def test_validate_downstream_unreachable_returns_502():
    client = make_client()
    with patch.object(policy_service.http_client, "post",
                      side_effect=requests.exceptions.ConnectionError):
        resp = client.post("/validate", json={"expense_id": "EXP-4",
                                              "amount": 100, "category": "travel"})
    assert resp.status_code == 502
    assert resp.get_json()["error"] == "downstream_unreachable"


def test_response_echoes_request_id_header():
    client = make_client()
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    with patch.object(policy_service.http_client, "get", return_value=mock_resp):
        resp = client.get("/health", headers={"X-Request-ID": "test-rid-456"})
    assert resp.headers["X-Request-ID"] == "test-rid-456"


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
    with patch.object(policy_service.time, "sleep") as mock_sleep:
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
    with patch.object(policy_service.time, "sleep") as mock_sleep:
        resp = client.get("/slow?delay=9999")
    assert resp.status_code == 200
    mock_sleep.assert_called_once_with(30.0)


def test_error_endpoint_triggers_500_handler():
    policy_service.app.testing = False
    client = policy_service.app.test_client()
    resp = client.get("/error")
    policy_service.app.testing = True
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
    policy_service.app.testing = False
    client = policy_service.app.test_client()
    with patch.object(policy_service.http_client, "post",
                      side_effect=RuntimeError("unexpected")):
        resp = client.post("/validate", json={"expense_id": "EXP-5",
                                              "amount": 100, "category": "travel"})
    policy_service.app.testing = True
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
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    with patch.object(policy_service.http_client, "get", return_value=mock_resp):
        client.get("/health")
    body = client.get("/metrics").get_data(as_text=True)
    assert 'http_requests_total{' in body
    assert 'route="/health"' in body
