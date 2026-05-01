"""Server-side world atlas: every device's discovered blocks, landmarks
and movement events go here so the cluster shares one global map.

Storage:
* blocks: SQLite table keyed by (x,y,z) — handles millions of rows
  efficiently while individual JSON files would not.
* landmarks: small JSON file (named locations).
* events: ring-buffer JSON file for the most recent 10k turtle
  movement / dig / scan events, used by the dashboard live feed.

Pathfinding (A*) reads from blocks and treats anything not in the
table OR named *_air as passable.
"""
from __future__ import annotations
import heapq
import json
import os
import sqlite3
import threading
import time

# --------------------------------------------------------------------------

_AIR = {"minecraft:air", "minecraft:cave_air", "minecraft:void_air"}


def _now_ms() -> int:
    return int(time.time() * 1000)


class AtlasStore:
    def __init__(self, root: str):
        self.root = root
        os.makedirs(root, exist_ok=True)
        self.db_path = os.path.join(root, "blocks.sqlite")
        self.landmarks_path = os.path.join(root, "landmarks.json")
        self.events_path = os.path.join(root, "events.json")
        self.lock = threading.RLock()
        self._init_db()
        if not os.path.isfile(self.landmarks_path):
            self._write_json(self.landmarks_path, {})
        if not os.path.isfile(self.events_path):
            self._write_json(self.events_path, [])

    # ---- low level ------------------------------------------------------

    def _init_db(self):
        with self.lock:
            self._conn = sqlite3.connect(self.db_path, check_same_thread=False)
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA synchronous=NORMAL")
            self._conn.execute("""
                CREATE TABLE IF NOT EXISTS blocks (
                    x INTEGER NOT NULL,
                    y INTEGER NOT NULL,
                    z INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    by TEXT,
                    ts INTEGER,
                    PRIMARY KEY (x, y, z)
                )""")
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_blocks_name ON blocks(name)")
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_blocks_y ON blocks(y)")

            # Storage snapshot: per-(device, item) totals. Each storage
            # node POSTs its full pool periodically and replaces its
            # rows for that device — so removing items from a node
            # propagates without manual deletes.
            self._conn.execute("""
                CREATE TABLE IF NOT EXISTS storage_items (
                    device TEXT NOT NULL,
                    name   TEXT NOT NULL,
                    count  INTEGER NOT NULL,
                    ts     INTEGER NOT NULL,
                    PRIMARY KEY (device, name)
                )""")
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_storage_name ON storage_items(name)")
            self._conn.commit()

    def _read_json(self, path: str):
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            return None

    def _write_json(self, path: str, data) -> None:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
        os.replace(tmp, path)

    # ---- blocks ---------------------------------------------------------

    def upsert_blocks(self, items: list[dict], by: str | None) -> int:
        """Insert/update many block records in one transaction. Returns N."""
        ts = _now_ms()
        rows = []
        for it in items or []:
            try:
                x = int(it["x"]); y = int(it["y"]); z = int(it["z"])
            except (KeyError, TypeError, ValueError):
                continue
            name = str(it.get("name") or "minecraft:unknown")
            rows.append((x, y, z, name, by, int(it.get("ts") or ts)))
        if not rows:
            return 0
        with self.lock:
            self._conn.executemany(
                "INSERT INTO blocks(x,y,z,name,by,ts) VALUES(?,?,?,?,?,?) "
                "ON CONFLICT(x,y,z) DO UPDATE SET name=excluded.name, "
                "by=excluded.by, ts=excluded.ts",
                rows)
            self._conn.commit()
        return len(rows)

    def query_blocks(self, *, bbox=None, kinds=None, name=None, limit=10000):
        """bbox = (x1,y1,z1,x2,y2,z2). kinds = ['ore_diamond', ...] interpreted
        as block-name substrings; name = exact match."""
        where = []
        args = []
        if bbox:
            x1, y1, z1, x2, y2, z2 = bbox
            xa, xb = sorted([x1, x2]); ya, yb = sorted([y1, y2]); za, zb = sorted([z1, z2])
            where.append("x BETWEEN ? AND ? AND y BETWEEN ? AND ? AND z BETWEEN ? AND ?")
            args.extend([xa, xb, ya, yb, za, zb])
        if name:
            where.append("name = ?"); args.append(name)
        if kinds:
            ors = " OR ".join("name LIKE ?" for _ in kinds)
            where.append("(" + ors + ")")
            args.extend("%" + k + "%" for k in kinds)
        sql = "SELECT x,y,z,name,by,ts FROM blocks"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " LIMIT " + str(int(limit))
        with self.lock:
            cur = self._conn.execute(sql, args)
            return [
                {"x": r[0], "y": r[1], "z": r[2],
                 "name": r[3], "by": r[4], "ts": r[5]}
                for r in cur.fetchall()
            ]

    def stats(self) -> dict:
        with self.lock:
            cur = self._conn.execute("SELECT COUNT(*) FROM blocks")
            total = cur.fetchone()[0]
            cur = self._conn.execute(
                "SELECT name, COUNT(*) c FROM blocks GROUP BY name "
                "ORDER BY c DESC LIMIT 32")
            top = [{"name": r[0], "count": r[1]} for r in cur.fetchall()]
        return {"total": total, "top": top}

    def block_at(self, x: int, y: int, z: int) -> dict | None:
        with self.lock:
            cur = self._conn.execute(
                "SELECT name, by, ts FROM blocks WHERE x=? AND y=? AND z=?",
                (x, y, z))
            r = cur.fetchone()
        if not r:
            return None
        return {"x": x, "y": y, "z": z, "name": r[0], "by": r[1], "ts": r[2]}

    # ---- storage --------------------------------------------------------

    def replace_storage(self, device: str, items: list[dict]) -> int:
        """Replace this device's full storage snapshot in one transaction.
        items = [{name, count}, ...]."""
        ts = _now_ms()
        rows = []
        for it in items or []:
            n = str(it.get("name") or "")
            c = int(it.get("count") or 0)
            if n and c > 0:
                rows.append((device, n, c, ts))
        with self.lock:
            self._conn.execute("DELETE FROM storage_items WHERE device=?", (device,))
            if rows:
                self._conn.executemany(
                    "INSERT INTO storage_items(device,name,count,ts) VALUES(?,?,?,?)",
                    rows)
            self._conn.commit()
        return len(rows)

    def storage_items(self, *, name: str | None = None,
                      device: str | None = None,
                      pattern: str | None = None,
                      limit: int = 5000) -> dict:
        """Aggregate query: returns { totals=[...], breakdown=[...] }.
        Each totals entry sums count across devices; breakdown is per-
        (device,name) row."""
        where = []; args = []
        if device: where.append("device=?"); args.append(device)
        if name:   where.append("name=?");   args.append(name)
        if pattern:
            where.append("name LIKE ?")
            args.append("%" + pattern + "%")
        sql = "SELECT device, name, count, ts FROM storage_items"
        if where: sql += " WHERE " + " AND ".join(where)
        sql += " LIMIT " + str(int(limit))
        with self.lock:
            cur = self._conn.execute(sql, args)
            breakdown = [
                {"device": r[0], "name": r[1], "count": r[2], "ts": r[3]}
                for r in cur.fetchall()
            ]
        agg: dict[str, dict] = {}
        for r in breakdown:
            t = agg.setdefault(r["name"], {"name": r["name"], "count": 0, "devices": []})
            t["count"] += r["count"]
            t["devices"].append({"device": r["device"], "count": r["count"]})
        totals = list(agg.values())
        totals.sort(key=lambda x: -x["count"])
        return {"totals": totals, "breakdown": breakdown}

    # ---- landmarks ------------------------------------------------------

    def landmarks(self) -> dict:
        return self._read_json(self.landmarks_path) or {}

    def add_landmark(self, name: str, x: int, y: int, z: int,
                     tags=None, by=None) -> dict:
        with self.lock:
            data = self.landmarks()
            data[name] = {
                "name": name, "x": x, "y": y, "z": z,
                "tags": list(tags or []), "by": by, "ts": _now_ms(),
            }
            self._write_json(self.landmarks_path, data)
            return data[name]

    def remove_landmark(self, name: str) -> bool:
        with self.lock:
            data = self.landmarks()
            if name not in data:
                return False
            del data[name]
            self._write_json(self.landmarks_path, data)
            return True

    # ---- events ---------------------------------------------------------

    def push_events(self, items: list[dict], by: str | None,
                    max_keep: int = 10000) -> int:
        if not items:
            return 0
        ts = _now_ms()
        normalized = []
        for it in items:
            it = dict(it)
            it["by"] = by or it.get("by")
            it["ts"] = int(it.get("ts") or ts)
            normalized.append(it)
        with self.lock:
            data = self._read_json(self.events_path) or []
            data.extend(normalized)
            if len(data) > max_keep:
                data = data[-max_keep:]
            self._write_json(self.events_path, data)
        return len(normalized)

    def recent_events(self, since_ts: int = 0, limit: int = 500) -> list[dict]:
        data = self._read_json(self.events_path) or []
        if since_ts:
            data = [e for e in data if (e.get("ts") or 0) > since_ts]
        return data[-limit:]

    # ---- A* pathfinding -------------------------------------------------

    def find_path(self, start, goal, *, max_iters: int = 50000):
        """A* in 3D over the known blocks. A cell is passable if no block
        is recorded there OR the recorded block is air.
        Returns list of (x,y,z) including start and goal, or None."""
        sx, sy, sz = (int(v) for v in start)
        gx, gy, gz = (int(v) for v in goal)

        with self.lock:
            x1, x2 = sorted([sx, gx]); y1, y2 = sorted([sy, gy]); z1, z2 = sorted([sz, gz])
            pad = 4
            cur = self._conn.execute(
                "SELECT x,y,z,name FROM blocks WHERE "
                "x BETWEEN ? AND ? AND y BETWEEN ? AND ? AND z BETWEEN ? AND ?",
                (x1 - pad, x2 + pad, y1 - pad, y2 + pad, z1 - pad, z2 + pad))
            local_blocks = {(r[0], r[1], r[2]): r[3] for r in cur.fetchall()}

        def passable(p):
            n = local_blocks.get(p)
            return n is None or n in _AIR

        def heur(p):
            return abs(p[0] - gx) + abs(p[1] - gy) + abs(p[2] - gz)

        if not passable((gx, gy, gz)):
            return None
        open_heap = [(heur((sx, sy, sz)), 0, (sx, sy, sz))]
        came = {}
        gscore = {(sx, sy, sz): 0}
        iters = 0
        DIRS = [(1,0,0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1)]
        while open_heap:
            iters += 1
            if iters > max_iters:
                return None
            _, g, p = heapq.heappop(open_heap)
            if p == (gx, gy, gz):
                path = [p]
                while p in came:
                    p = came[p]
                    path.append(p)
                path.reverse()
                return path
            for dx, dy, dz in DIRS:
                np = (p[0] + dx, p[1] + dy, p[2] + dz)
                if not passable(np):
                    continue
                ng = g + 1
                if ng < gscore.get(np, 1 << 30):
                    gscore[np] = ng
                    came[np] = p
                    heapq.heappush(open_heap, (ng + heur(np), ng, np))
        return None
