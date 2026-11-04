"""APNs push for Alfred: token-based (ES256 JWT) auth over HTTP/2, per
PROTOCOL.md. A clean no-op (`configured: false`) whenever
~/.alfred/apns.json is absent -- no APNs dependency is required to run
alfredd without push.

apns.json: {"team_id","key_id","p8_path","topic","env":"production"|"sandbox"}
"""
import json
import time
from typing import Optional

from . import config, db

APNS_HOSTS = {
    "production": "https://api.push.apple.com",
    "sandbox": "https://api.sandbox.push.apple.com",
}

_jwt_cache = {"token": None, "built": 0.0, "kid": None}
_JWT_TTL = 50 * 60  # Apple tokens are valid up to 1h; refresh well inside that.


def load_apns_config() -> Optional[dict]:
    if not config.APNS_CONFIG_FILE.exists():
        return None
    try:
        cfg = json.loads(config.APNS_CONFIG_FILE.read_text())
    except (OSError, ValueError):
        return None
    required = ("team_id", "key_id", "p8_path", "topic")
    if not all(cfg.get(k) for k in required):
        return None
    cfg.setdefault("env", "production")
    return cfg


def _build_jwt(cfg: dict) -> str:
    """ES256 JWT per Apple's token-based provider auth, cached ~50 min."""
    if (_jwt_cache["token"] and _jwt_cache["kid"] == cfg["key_id"]
            and time.time() - _jwt_cache["built"] < _JWT_TTL):
        return _jwt_cache["token"]
    import jwt as pyjwt  # PyJWT

    with open(cfg["p8_path"]) as f:
        private_key = f.read()
    token = pyjwt.encode(
        {"iss": cfg["team_id"], "iat": int(time.time())},
        private_key,
        algorithm="ES256",
        headers={"kid": cfg["key_id"]},
    )
    _jwt_cache.update(token=token, built=time.time(), kid=cfg["key_id"])
    return token


def status() -> dict:
    cfg = load_apns_config()
    if not cfg:
        return {"configured": False, "devices": db.count_devices()}
    return {"configured": True, "team_id": cfg["team_id"], "key_id": cfg["key_id"],
            "topic": cfg["topic"], "devices": db.count_devices()}


def _send_one(client, cfg: dict, device_token: str, jwt_token: str, payload: dict) -> tuple:
    """Returns (ok: bool, should_prune: bool)."""
    host = APNS_HOSTS.get(cfg.get("env", "production"), APNS_HOSTS["production"])
    url = f"{host}/3/device/{device_token}"
    headers = {
        "authorization": f"bearer {jwt_token}",
        "apns-topic": cfg["topic"],
        "apns-push-type": "alert",
        "content-type": "application/json",
    }
    try:
        r = client.post(url, headers=headers, json=payload, timeout=10)
    except Exception:
        return False, False
    if r.status_code == 200:
        return True, False
    reason = None
    try:
        reason = r.json().get("reason")
    except Exception:
        pass
    should_prune = r.status_code == 410 or reason in ("BadDeviceToken", "Unregistered")
    return False, should_prune


def notify(title: str, body: str, session_id: Optional[str] = None) -> dict:
    """Push `title`/`body` to every registered device. No-op with
    configured:false when ~/.alfred/apns.json is absent."""
    cfg = load_apns_config()
    devices = db.list_devices()
    if not cfg:
        return {"sent": 0, "failed": 0, "configured": False}
    if not devices:
        return {"sent": 0, "failed": 0, "configured": True}

    import httpx

    jwt_token = _build_jwt(cfg)
    payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default"}}
    if session_id:
        payload["session_id"] = session_id

    sent = failed = 0
    with httpx.Client(http2=True) as client:
        for dev in devices:
            ok, should_prune = _send_one(client, cfg, dev["token"], jwt_token, payload)
            if ok:
                sent += 1
            else:
                failed += 1
                if should_prune:
                    db.delete_device(dev["token"])
    return {"sent": sent, "failed": failed, "configured": True}


def notify_turn_finished(session_title: str, first_line: str, session_id: str) -> dict:
    # PROTOCOL.md: "Alfred finished: <first line of reply>".
    return notify("Alfred finished", first_line or session_title, session_id=session_id)
