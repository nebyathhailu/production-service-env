import sys
from pathlib import Path
from unittest.mock import patch

import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app as service_a  # noqa: E402


def make_client():
    service_a.app.testing = True
    return service_a.app.test_client()


def test_health_returns_200_and_service_metadata():
    client = make_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["service"] == "service-a"
    assert body["status"] == "healthy"


def test_unknown_route_returns_structured_404():
    client = make_client()
    resp = client.get("/nope")
    assert resp.status_code == 404
    body = resp.get_json()
    assert body["error"] == "route not found"


def test_greet_service_b_success():
    client = make_client()
    with patch.object(service_a.requests, "get") as mock_get:
        mock_get.return_value.status_code = 200
        mock_get.return_value.raise_for_status.return_value = None
        resp = client.get("/greet-service-b")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "success"


def test_greet_service_b_downstream_failure_returns_502():
    client = make_client()
    with patch.object(service_a.requests, "get", side_effect=requests.exceptions.ConnectionError):
        resp = client.get("/greet-service-b")
    assert resp.status_code == 502
    body = resp.get_json()
    assert body["status"] == "error"


def test_greeting_received_callback():
    client = make_client()
    resp = client.post("/greeting-rcvd", json={"request_id": "abc", "source_service": "service-c"})
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "received"


def test_response_echoes_request_id_header():
    client = make_client()
    resp = client.get("/health", headers={"X-Request-ID": "test-rid-123"})
    assert resp.headers["X-Request-ID"] == "test-rid-123"


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
