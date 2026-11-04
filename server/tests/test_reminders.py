def test_create_list_delete_reminder(client, auth_headers):
    body = {"title": "Renew NAFDAC filing", "body": "Deadline for the annual filing",
            "fire_at": "2026-12-01T09:00:00Z"}
    r = client.post("/reminders", json=body, headers=auth_headers)
    assert r.status_code == 200
    created = r.json()
    assert created["title"] == body["title"]
    assert created["fire_at"] == body["fire_at"]
    rid = created["id"]
    assert rid

    r = client.get("/reminders", headers=auth_headers)
    assert r.status_code == 200
    reminders = r.json()["reminders"]
    assert any(x["id"] == rid for x in reminders)

    r = client.delete(f"/reminders/{rid}", headers=auth_headers)
    assert r.status_code == 200
    assert r.json() == {"ok": True}

    r = client.get("/reminders", headers=auth_headers)
    assert all(x["id"] != rid for x in r.json()["reminders"])


def test_reminders_after_filter(client, auth_headers):
    for fire_at in ("2026-01-01T00:00:00Z", "2026-06-01T00:00:00Z", "2026-12-31T00:00:00Z"):
        client.post("/reminders", json={"title": "x", "body": "y", "fire_at": fire_at},
                     headers=auth_headers)

    r = client.get("/reminders", params={"after": "2026-06-01T00:00:00Z"}, headers=auth_headers)
    fire_ats = [x["fire_at"] for x in r.json()["reminders"]]
    assert fire_ats == ["2026-12-31T00:00:00Z"]

    r = client.get("/reminders", params={"after": "2025-01-01T00:00:00Z"}, headers=auth_headers)
    assert len(r.json()["reminders"]) == 3


def test_reminder_carries_session_id(client, auth_headers):
    body = {"title": "Follow up", "body": "check results", "fire_at": "2026-07-01T00:00:00Z",
            "session_id": "abc123"}
    r = client.post("/reminders", json=body, headers=auth_headers)
    assert r.json()["session_id"] == "abc123"
