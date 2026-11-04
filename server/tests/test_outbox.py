from alfredd import db, outbox


def _create(client, auth_headers, **overrides):
    body = {"kind": "email", "to": "someone@example.com", "subject": "Hi",
            "body": "Draft body"}
    body.update(overrides)
    return client.post("/outbox", json=body, headers=auth_headers)


def test_create_outbox_item_is_pending(client, auth_headers):
    r = _create(client, auth_headers)
    assert r.status_code == 200
    item = r.json()
    assert item["status"] == "pending"
    assert item["recipient"] == "someone@example.com"
    assert item["subject"] == "Hi"

    r = client.get("/outbox", headers=auth_headers)
    assert any(x["id"] == item["id"] for x in r.json()["outbox"])


def test_reject_outbox_item(client, auth_headers):
    item = _create(client, auth_headers).json()
    r = client.post(f"/outbox/{item['id']}/reject", headers=auth_headers)
    assert r.status_code == 200
    assert r.json()["status"] == "rejected"

    # Rejecting twice is a conflict, not a silent success.
    r = client.post(f"/outbox/{item['id']}/reject", headers=auth_headers)
    assert r.status_code == 409


def test_approve_from_local_box_is_403(client, auth_headers):
    """The `client` fixture looks like 127.0.0.1 with no X-Alfred-Route
    header; exactly the brain's own local curl path; and must be rejected
    regardless of outbox item state. This is the path the task asked to
    verify instead of actually sending a real email."""
    item = _create(client, auth_headers).json()
    r = client.post(f"/outbox/{item['id']}/approve", headers=auth_headers)
    assert r.status_code == 403
    assert db.get_outbox_item(item["id"])["status"] == "pending"


def test_approve_still_403_with_bogus_route_header(client, auth_headers):
    item = _create(client, auth_headers).json()
    r = client.post(f"/outbox/{item['id']}/approve",
                     headers={**auth_headers, "x-alfred-route": "internal"})
    assert r.status_code == 403


def test_approve_allowed_from_remote_wg0_peer(remote_client, auth_headers, monkeypatch):
    """A real phone/app on wg0 (not the box itself) may approve."""
    sent = {}

    def fake_send(to, subject, body, attachments=None):
        sent.update(to=to, subject=subject, body=body)

    monkeypatch.setattr(outbox, "send_email", fake_send)

    item = _create(remote_client, auth_headers).json()
    r = remote_client.post(f"/outbox/{item['id']}/approve", headers=auth_headers)
    assert r.status_code == 200
    assert r.json()["status"] == "sent"
    assert sent["to"] == "someone@example.com"


def test_approve_allowed_with_public_route_header(client, auth_headers, monkeypatch):
    """The box itself may still approve if the request is marked as having
    come through the public reverse-proxy route."""
    monkeypatch.setattr(outbox, "send_email", lambda *a, **k: None)
    item = _create(client, auth_headers).json()
    r = client.post(f"/outbox/{item['id']}/approve",
                     headers={**auth_headers, "x-alfred-route": "public"})
    assert r.status_code == 200
    assert r.json()["status"] == "sent"


def test_unsupported_kind_rejected(client, auth_headers):
    r = _create(client, auth_headers, kind="sms")
    assert r.status_code == 400


def test_outbox_item_not_found(client, auth_headers):
    r = client.post("/outbox/doesnotexist/reject", headers=auth_headers)
    assert r.status_code == 404
