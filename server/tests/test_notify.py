import json

import jwt as pyjwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from alfredd import config, db, push


def test_notify_unconfigured_is_clean_noop(client, auth_headers):
    # No ~/.alfred/apns.json written in this test -> configured:false, no error.
    assert not config.APNS_CONFIG_FILE.exists()
    r = client.post("/notify", json={"title": "hi", "body": "there"}, headers=auth_headers)
    assert r.status_code == 200
    assert r.json() == {"sent": 0, "failed": 0, "configured": False}


def test_push_status_unconfigured(client, auth_headers):
    r = client.get("/push/status", headers=auth_headers)
    assert r.status_code == 200
    body = r.json()
    assert body["configured"] is False
    assert "devices" in body


@pytest.fixture
def apns_setup(tmp_path, client):
    """Writes a real EC key + apns.json, registers one device."""
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    p8_path = tmp_path / "AuthKey_TESTKEY1.p8"
    p8_path.write_bytes(pem)

    cfg = {"team_id": "TEAMID001", "key_id": "TESTKEY1", "p8_path": str(p8_path),
           "topic": "org.zyco.alfred", "env": "sandbox"}
    config.APNS_CONFIG_FILE.write_text(json.dumps(cfg))

    db.upsert_device("devtok-live", "sandbox", "org.zyco.alfred")

    public_key = key.public_key()
    push._jwt_cache.update(token=None, built=0.0, kid=None)  # ensure a fresh JWT is built
    return cfg, public_key


class _FakeResponse:
    def __init__(self, status_code, reason=None):
        self.status_code = status_code
        self._reason = reason

    def json(self):
        if self._reason is None:
            return {}
        return {"reason": self._reason}


class _FakeClient:
    """Stands in for httpx.Client(http2=True) as a context manager."""
    calls = []

    def __init__(self, *a, **kw):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def post(self, url, headers=None, json=None, timeout=None):
        _FakeClient.calls.append({"url": url, "headers": headers, "json": json})
        return _FakeClient._next_response


def test_notify_sends_signed_jwt_to_apns(client, auth_headers, apns_setup, monkeypatch):
    cfg, public_key = apns_setup
    _FakeClient.calls = []
    _FakeClient._next_response = _FakeResponse(200)
    monkeypatch.setattr("httpx.Client", _FakeClient)

    r = client.post("/notify", json={"title": "Alfred finished", "body": "the draft is ready",
                                      "session_id": "sess-1"}, headers=auth_headers)
    assert r.status_code == 200
    assert r.json() == {"sent": 1, "failed": 0, "configured": True}

    assert len(_FakeClient.calls) == 1
    call = _FakeClient.calls[0]
    assert call["url"] == "https://api.sandbox.push.apple.com/3/device/devtok-live"
    assert call["headers"]["apns-topic"] == "org.zyco.alfred"
    assert call["headers"]["apns-push-type"] == "alert"
    assert call["json"]["aps"]["alert"] == {"title": "Alfred finished", "body": "the draft is ready"}
    assert call["json"]["session_id"] == "sess-1"

    bearer = call["headers"]["authorization"]
    assert bearer.startswith("bearer ")
    raw_jwt = bearer[len("bearer "):]
    header = pyjwt.get_unverified_header(raw_jwt)
    assert header["kid"] == "TESTKEY1"
    claims = pyjwt.decode(raw_jwt, public_key, algorithms=["ES256"])
    assert claims["iss"] == "TEAMID001"
    assert "iat" in claims


def test_notify_prunes_device_on_410(client, auth_headers, apns_setup, monkeypatch):
    _FakeClient.calls = []
    _FakeClient._next_response = _FakeResponse(410, reason="Unregistered")
    monkeypatch.setattr("httpx.Client", _FakeClient)

    assert db.count_devices() == 1
    r = client.post("/notify", json={"title": "x", "body": "y"}, headers=auth_headers)
    assert r.status_code == 200
    assert r.json() == {"sent": 0, "failed": 1, "configured": True}
    assert db.count_devices() == 0


def test_notify_prunes_device_on_bad_device_token_reason(client, auth_headers, apns_setup, monkeypatch):
    _FakeClient.calls = []
    _FakeClient._next_response = _FakeResponse(400, reason="BadDeviceToken")
    monkeypatch.setattr("httpx.Client", _FakeClient)

    r = client.post("/notify", json={"title": "x", "body": "y"}, headers=auth_headers)
    assert r.json()["failed"] == 1
    assert db.count_devices() == 0
