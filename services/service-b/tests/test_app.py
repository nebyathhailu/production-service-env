import sys
from pathlib import Path
from unittest.mock import patch

import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app as service_b  # noqa: E402


def make_client():
    service_b.app.testing = True
    return service_b.app.test_client()


def test_health_returns_200_and_service_metadata():
    client = make_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["service"] == "service-b"
    assert body["status"] == "healthy"


def test_unknown_route_returns_structured_404():
    client = make_client()
    resp = client.get("/nope")
    assert resp.status_code == 404
    body = resp.get_json()
    assert body["error"] == "route_not_found"


def test_greet_forwards_to_service_c_success():
    client = make_client()
    with patch.object(service_b.requests, "get") as mock_get:
        mock_get.return_value.status_code = 200
        mock_get.return_value.raise_for_status.return_value = None
        resp = client.get("/greet")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "forwarded"
    assert body["target"] == "service-c"


def test_greet_downstream_unreachable_returns_502():
    client = make_client()
    with patch.object(service_b.requests, "get", side_effect=requests.exceptions.ConnectionError):
        resp = client.get("/greet")
    assert resp.status_code == 502
    assert resp.get_json()["error"] == "downstream_unreachable"


def test_response_echoes_request_id_header():
    client = make_client()
    resp = client.get("/health", headers={"X-Request-ID": "test-rid-456"})
    assert resp.headers["X-Request-ID"] == "test-rid-456"
