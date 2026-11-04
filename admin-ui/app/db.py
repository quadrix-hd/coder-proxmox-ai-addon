import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone

DB_PATH = os.environ.get("ADMIN_UI_DB_PATH", "/data/db/admin-ui.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS sites (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    site_name TEXT UNIQUE NOT NULL,
    customer_domain TEXT NOT NULL DEFAULT '',
    docker_image TEXT NOT NULL DEFAULT '',
    target_node TEXT NOT NULL DEFAULT '',
    production_ip TEXT NOT NULL DEFAULT '',
    pangolin_site_id TEXT NOT NULL DEFAULT '',
    pangolin_resource_id TEXT NOT NULL DEFAULT '',
    pangolin_managed INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'pending',
    last_error TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


@contextmanager
def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with get_conn() as conn:
        conn.executescript(SCHEMA)


def create_site(site_name: str, customer_domain: str, docker_image: str) -> int:
    now = _now()
    with get_conn() as conn:
        cur = conn.execute(
            """INSERT INTO sites (site_name, customer_domain, docker_image, status, created_at, updated_at)
               VALUES (?, ?, ?, 'provisioning', ?, ?)""",
            (site_name, customer_domain, docker_image, now, now),
        )
        return cur.lastrowid


def update_site(site_name: str, **fields):
    if not fields:
        return
    fields["updated_at"] = _now()
    columns = ", ".join(f"{k} = ?" for k in fields)
    values = list(fields.values()) + [site_name]
    with get_conn() as conn:
        conn.execute(f"UPDATE sites SET {columns} WHERE site_name = ?", values)


def get_site(site_name: str):
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM sites WHERE site_name = ?", (site_name,)).fetchone()
        return dict(row) if row else None


def list_sites():
    with get_conn() as conn:
        rows = conn.execute("SELECT * FROM sites ORDER BY created_at DESC").fetchall()
        return [dict(r) for r in rows]


def delete_site(site_name: str):
    with get_conn() as conn:
        conn.execute("DELETE FROM sites WHERE site_name = ?", (site_name,))


def site_exists(site_name: str) -> bool:
    return get_site(site_name) is not None
