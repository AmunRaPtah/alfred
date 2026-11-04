"""Points ALFRED_HOME at a fresh temp dir before alfredd is ever imported,
so tests never touch the real ~/.alfred on this box."""
import os
import sys
import tempfile
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="alfredd-test-")
os.environ["ALFRED_HOME"] = _TMP

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pytest  # noqa: E402

from alfredd import config, db  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_tables():
    """devices/reminders share one on-disk db for the whole test session;
    reset both tables before every test so cases can't see each other's rows."""
    db.init_db()
    with db._conn() as conn:
        conn.execute("DELETE FROM devices")
        conn.execute("DELETE FROM reminders")
    config.APNS_CONFIG_FILE.unlink(missing_ok=True)
    yield


@pytest.fixture
def token():
    config.ensure_dirs()
    return config.ensure_token()


@pytest.fixture
def client(token):
    db.init_db()
    from alfredd.main import app
    from fastapi.testclient import TestClient
    with TestClient(app) as c:
        yield c


@pytest.fixture
def auth_headers(token):
    return {"authorization": f"Bearer {token}"}
