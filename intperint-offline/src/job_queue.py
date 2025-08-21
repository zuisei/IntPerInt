from __future__ import annotations
import os
import sqlite3
import json
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

BASE_DIR = Path(__file__).resolve().parent.parent
DB_PATH = BASE_DIR / "job_queue.sqlite3"

class JobQueue:
    """SQLite FIFO job queue (offline friendly).
    Schema:
      jobs(id TEXT PRIMARY KEY, type TEXT, payload TEXT, status TEXT, result TEXT, created REAL, updated REAL, cancelled INTEGER)
    Status: queued|running|done|error|cancelled
    """
    def __init__(self, db_path: Path = DB_PATH):
        self.db_path = Path(db_path)
        self._init_db()

    def _conn(self):
        return sqlite3.connect(self.db_path)

    def _init_db(self):
        conn = self._conn()
        try:
            cur = conn.cursor()
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    type TEXT,
                    payload TEXT,
                    status TEXT,
                    result TEXT,
                    created REAL,
                    updated REAL,
                    cancelled INTEGER DEFAULT 0
                )
                """
            )
            cur.execute("CREATE INDEX IF NOT EXISTS idx_status_created ON jobs(status, created)")
            conn.commit()
        finally:
            conn.close()

    def enqueue(self, type_: str, payload: Dict[str, Any]) -> str:
        jid = str(uuid.uuid4())
        now = time.time()
        conn = self._conn()
        try:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO jobs(id, type, payload, status, result, created, updated, cancelled) VALUES(?,?,?,?,?,?,?,0)",
                (jid, type_, json.dumps(payload), "queued", None, now, now),
            )
            conn.commit()
        finally:
            conn.close()
        return jid

    def dequeue(self) -> Optional[Tuple[str, str, Dict[str, Any]]]:
        conn = self._conn()
        try:
            cur = conn.cursor()
            cur.execute("SELECT id, type, payload FROM jobs WHERE status='queued' AND cancelled=0 ORDER BY created ASC LIMIT 1")
            row = cur.fetchone()
            if not row:
                return None
            jid, type_, payload = row[0], row[1], json.loads(row[2])
            cur.execute("UPDATE jobs SET status='running', updated=? WHERE id=?", (time.time(), jid))
            conn.commit()
            return jid, type_, payload
        finally:
            conn.close()

    def set_result(self, job_id: str, status: str, result: Dict[str, Any]):
        conn = self._conn()
        try:
            cur = conn.cursor()
            cur.execute(
                "UPDATE jobs SET status=?, result=?, updated=? WHERE id=?",
                (status, json.dumps(result), time.time(), job_id),
            )
            conn.commit()
        finally:
            conn.close()

    def status(self, job_id: str) -> Dict[str, Any]:
        conn = self._conn()
        try:
            cur = conn.cursor()
            cur.execute("SELECT id, type, status, result, created, updated, cancelled FROM jobs WHERE id=?", (job_id,))
            row = cur.fetchone()
            if not row:
                return {"error": "not_found"}
            return {
                "id": row[0],
                "type": row[1],
                "status": row[2],
                "result": json.loads(row[3]) if row[3] else None,
                "created": row[4],
                "updated": row[5],
                "cancelled": bool(row[6]),
            }
        finally:
            conn.close()

    def cancel(self, job_id: str) -> bool:
        conn = self._conn()
        try:
            cur = conn.cursor()
            cur.execute("UPDATE jobs SET cancelled=1, status='cancelled', updated=? WHERE id=?", (time.time(), job_id))
            conn.commit()
            return cur.rowcount > 0
        finally:
            conn.close()
