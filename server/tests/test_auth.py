def test_health_is_public(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_missing_token_rejected(client):
    r = client.get("/harnesses")
    assert r.status_code == 401


def test_bad_token_rejected(client):
    r = client.get("/harnesses", headers={"authorization": "Bearer not-the-token"})
    assert r.status_code == 401


def test_good_token_accepted(client, auth_headers):
    r = client.get("/harnesses", headers=auth_headers)
    assert r.status_code == 200
    harnesses = r.json()
    assert len(harnesses) == 1
    assert harnesses[0]["id"] == "alfred"
    assert harnesses[0]["command"] == "alfred"
