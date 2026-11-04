from alfredd import db


def test_register_device_upserts(client, auth_headers):
    body = {"token": "devtok-1", "env": "sandbox", "bundle_id": "org.zyco.alfred"}
    r = client.post("/devices", json=body, headers=auth_headers)
    assert r.status_code == 200
    assert r.json() == {"ok": True}
    devices = db.list_devices()
    assert len(devices) == 1
    assert devices[0]["token"] == "devtok-1"
    assert devices[0]["env"] == "sandbox"

    # same token again, different env -> upsert, not a second row
    body["env"] = "production"
    r = client.post("/devices", json=body, headers=auth_headers)
    assert r.status_code == 200
    devices = db.list_devices()
    assert len(devices) == 1
    assert devices[0]["env"] == "production"


def test_register_device_bad_env_rejected(client, auth_headers):
    body = {"token": "devtok-2", "env": "staging", "bundle_id": "org.zyco.alfred"}
    r = client.post("/devices", json=body, headers=auth_headers)
    assert r.status_code == 400


def test_delete_device(client, auth_headers):
    client.post("/devices", json={"token": "devtok-3", "env": "sandbox",
                                   "bundle_id": "org.zyco.alfred"}, headers=auth_headers)
    assert db.count_devices() == 1
    r = client.delete("/devices/devtok-3", headers=auth_headers)
    assert r.status_code == 200
    assert r.json() == {"ok": True}
    assert db.count_devices() == 0


def test_delete_unknown_device_is_still_ok(client, auth_headers):
    r = client.delete("/devices/never-registered", headers=auth_headers)
    assert r.status_code == 200
    assert r.json() == {"ok": True}
