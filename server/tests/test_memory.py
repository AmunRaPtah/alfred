from alfredd import config, memory


def test_memory_empty_by_default(client, auth_headers):
    r = client.get("/memory", headers=auth_headers)
    assert r.status_code == 200
    assert r.json() == {"text": ""}


def test_remember_appends_a_fact(client, auth_headers):
    r = client.post("/memory/remember", json={"fact": "owner prefers batched Telegram digests"},
                     headers=auth_headers)
    assert r.status_code == 200
    assert "owner prefers batched Telegram digests" in r.json()["text"]

    r = client.get("/memory", headers=auth_headers)
    assert "owner prefers batched Telegram digests" in r.json()["text"]


def test_put_memory_replaces_text(client, auth_headers):
    client.put("/memory", json={"text": "# notes\n\n- fact one\n"}, headers=auth_headers)
    r = client.get("/memory", headers=auth_headers)
    assert r.json()["text"] == "# notes\n\n- fact one\n"


def test_memory_trims_oldest_facts_past_cap(client, auth_headers, monkeypatch):
    monkeypatch.setattr(config, "MEMORY_MAX_CHARS", 200)
    for i in range(30):
        client.post("/memory/remember", json={"fact": f"fact number {i} with some padding text"},
                     headers=auth_headers)
    text = client.get("/memory", headers=auth_headers).json()["text"]
    assert len(text) <= 200
    # Newest fact survives, an early one does not.
    assert "fact number 29" in text
    assert "fact number 0 " not in text
