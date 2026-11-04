"""SQLite storage for Alfred protocol additions: APNs device tokens and
reminders. One file, ~/.alfred/alfred.db, opened fresh per call (low
concurrency, no need for a pool) with WAL for safe concurrent readers.
"""
import sqlite3
import time
from contextlib import contextmanager

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    token TEXT PRIMARY KEY,
    env TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    created REAL NOT NULL,
    updated REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS reminders (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    fire_at TEXT NOT NULL,
    session_id TEXT,
    created REAL NOT NULL
);
"""


@contextmanager
def _conn():
    config.ALFRED_HOME.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(config.DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db():
    with _conn() as conn:
        conn.executescript(SCHEMA)


# ------------------------------------------------------------------ devices

def upsert_device(token: str, env: str, bundle_id: str) -> None:
    now = time.time()
    with _conn() as conn:
        conn.execute(
            """INSERT INTO devices (token, env, bundle_id, created, updated)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(token) DO UPDATE SET
                 env=excluded.env, bundle_id=excluded.bundle_id, updated=excluded.updated""",
            (token, env, bundle_id, now, now),
        )


def delete_device(token: str) -> None:
    with _conn() as conn:
        conn.execute("DELETE FROM devices WHERE token = ?", (token,))


def list_devices() -> list:
    with _conn() as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM devices")]


def count_devices() -> int:
    with _conn() as conn:
        return conn.execute("SELECT COUNT(*) FROM devices").fetchone()[0]


# ---------------------------------------------------------------- reminders

def create_reminder(rid: str, title: str, body: str, fire_at: str, session_id=None) -> dict:
    now = time.time()
    with _conn() as conn:
        conn.execute(
            "INSERT INTO reminders (id, title, body, fire_at, session_id, created) VALUES (?, ?, ?, ?, ?, ?)",
            (rid, title, body, fire_at, session_id, now),
        )
    return {"id": rid, "title": title, "body": body, "fire_at": fire_at, "session_id": session_id}


def delete_reminder(rid: str) -> None:
    with _conn() as conn:
        conn.execute("DELETE FROM reminders WHERE id = ?", (rid,))


def list_reminders(after: str = None) -> list:
    with _conn() as conn:
        if after:
            rows = conn.execute(
                "SELECT id, title, body, fire_at, session_id FROM reminders WHERE fire_at > ? ORDER BY fire_at ASC",
                (after,),
            )
        else:
            rows = conn.execute(
                "SELECT id, title, body, fire_at, session_id FROM reminders ORDER BY fire_at ASC"
            )
        return [dict(r) for r in rows]
