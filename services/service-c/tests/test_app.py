import sys
from pathlib import Path
from unittest.mock import patch

import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app as service_c  # noqa: E402


def make_client():
    service_c.app.testing = True
    return service_c.app.test_client()


def test_health_returns_200_and_service_metadata():
    client = make_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["service"] == "service-c"
    assert body["status"] == "healthy"


def test_unknown_route_returns_structured_404():
    client = make_client()
    resp = client.get("/nope")
    assert resp.status_code == 404
    body = resp.get_json()
    assert body["error"] == "route_not_found"


def test_greet_c_sends_callback_to_service_a():
    client = make_client()
    with patch.object(service_c.requests, "post") as mock_post:
        mock_post.return_value.status_code = 200
        mock_post.return_value.raise_for_status.return_value = None
        resp = client.get("/greet-c")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "processed"
    assert body["callback_sent"] is True


def test_greet_c_callback_failure_returns_502():
    client = make_client()
    with patch.object(service_c.requests, "post", side_effect=requests.exceptions.ConnectionError):
        resp = client.get("/greet-c")
    assert resp.status_code == 502
    body = resp.get_json()
    assert body["callback_sent"] is False
    assert body["error"] == "callback_failed"


def test_response_echoes_request_id_header():
    client = make_client()
    resp = client.get("/health", headers={"X-Request-ID": "test-rid-789"})
    assert resp.headers["X-Request-ID"] == "test-rid-789"
