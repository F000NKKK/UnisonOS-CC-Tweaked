#!/usr/bin/env python3
"""
UnisonOS package server + device message bus.

* Static file server for /srv/unison (HTTP on 9273, HTTPS on 9274).
* JSON API at /api/* (register, heartbeat, devices, messages, broadcast).
* WebSocket bus on ws://0.0.0.0:9275 and wss://0.0.0.0:9276 — devices that
  open a WS connection get messages pushed in real-time. HTTP polling is
  still supported as a fallback.

API auth: optional bearer token loaded from /etc/unison/api.token. WS auth:
the very first frame must be {"type":"auth","id":"<dev>","token":"..."}.
"""

from __future__ import annotations

import argparse
import asyncio
import http.server
import json
import os
import ssl
import sys
import threading
import time
import uuid
from functools import partial
from urllib.parse import parse_qs, urlparse


STATE_DIR_DEFAULT = "/srv/unison.state"
TOKEN_FILE_DEFAULT = "/etc/unison/api.token"


def _now_ms() -> int:
    return int(time.time() * 1000)


# --------------------------------------------------------------------------
# Persistent store. JSON files behind a single coarse lock — fine for our
# fleet sizes.
# --------------------------------------------------------------------------

class Store:
    """Tiny JSON-file store. One lock for the whole server."""

    def __init__(self, root: str):
        self.root = root
        self.devices_path = os.path.join(root, "devices.json")
        self.queues_dir = os.path.join(root, "queues")
        self.lock = threading.Lock()
        os.makedirs(root, exist_ok=True)
        os.makedirs(self.queues_dir, exist_ok=True)
        if not os.path.isfile(self.devices_path):
            self._write(self.devices_path, {})
        # Real-time push hook installed by WSHub once it's ready. None means
        # HTTP-only delivery (queue is the only path).
        self.push_hook = None  # type: ignore[assignment]

    @staticmethod
    def _read(path: str):
        if not os.path.isfile(path):
            return None
        with open(path, "r") as f:
            return json.load(f)

    @staticmethod
    def _write(path: str, data) -> None:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
        os.replace(tmp, path)

    # Stale-device pruning policy. Console sessions (web dashboards) get
    # evicted aggressively because every browser tab spawns a fresh
    # console-XXXX entry; without TTL they pile up forever. Real devices
    # (turtles, computers) get a longer TTL to survive transient outages.
    CONSOLE_TTL_MS = 5 * 60 * 1000        # 5 minutes
    DEVICE_TTL_MS  = 7 * 24 * 60 * 60 * 1000  # 7 days

    def _is_console(self, dev_id: str, info: dict) -> bool:
        if dev_id.startswith("console-"):
            return True
        if (info or {}).get("role") == "console":
            return True
        return False

    def _prune_stale(self, db: dict) -> bool:
        """Drop expired entries in-place. Returns True if anything was pruned."""
        now = _now_ms()
        changed = False
        for dev_id in list(db.keys()):
            info = db[dev_id] or {}
            seen = info.get("last_seen") or 0
            ttl = self.CONSOLE_TTL_MS if self._is_console(dev_id, info) else self.DEVICE_TTL_MS
            if now - seen > ttl:
                del db[dev_id]
                changed = True
        return changed

    def devices(self) -> dict:
        with self.lock:
            db = self._read(self.devices_path) or {}
            if self._prune_stale(db):
                self._write(self.devices_path, db)
            return db

    def upsert_device(self, device_id: str, info: dict) -> dict:
        with self.lock:
            db = self._read(self.devices_path) or {}
            existing = db.get(device_id, {})
            existing.update(info)
            existing["last_seen"] = _now_ms()
            db[device_id] = existing
            self._write(self.devices_path, db)
            return existing

    def queue_path(self, device_id: str) -> str:
        safe = "".join(c for c in device_id if c.isalnum() or c in "-_.")
        return os.path.join(self.queues_dir, safe + ".json")

    def push_message(self, device_id: str, msg: dict) -> dict:
        envelope = {
            "id": str(uuid.uuid4()),
            "ts": _now_ms(),
            "to": device_id,
            "msg": msg,
        }
        # Try real-time delivery first. If a WS subscriber is connected the
        # hook returns True and we DO NOT persist — otherwise the same
        # message would be duplicated when the client reconnects via HTTP
        # polling and pops the durable queue.
        delivered = False
        if self.push_hook:
            try:
                delivered = bool(self.push_hook(device_id, envelope))
            except Exception:
                delivered = False
        if not delivered:
            with self.lock:
                path = self.queue_path(device_id)
                queue = self._read(path) or []
                queue.append(envelope)
                self._write(path, queue)
        return envelope

    def pop_messages(self, device_id: str, max_count: int = 64,
                     max_age_ms: int = 60_000):
        """Pop up to max_count messages from the durable queue. Drops any
        envelope older than max_age_ms — stale work piled up while a device
        was offline shouldn't replay all at once on reconnect."""
        with self.lock:
            path = self.queue_path(device_id)
            queue = self._read(path) or []
            cutoff = _now_ms() - max_age_ms
            fresh = [e for e in queue if (e.get("ts") or 0) >= cutoff]
            taken = fresh[:max_count]
            remaining = fresh[max_count:]
            self._write(path, remaining)
            return taken

    def purge_queue(self, device_id: str) -> int:
        with self.lock:
            path = self.queue_path(device_id)
            queue = self._read(path) or []
            self._write(path, [])
            return len(queue)

    def purge_all_queues(self) -> int:
        with self.lock:
            n = 0
            for f in os.listdir(self.queues_dir):
                if f.endswith(".json"):
                    p = os.path.join(self.queues_dir, f)
                    try:
                        n += len(self._read(p) or [])
                    except Exception:
                        pass
                    self._write(p, [])
            return n


# --------------------------------------------------------------------------
# WebSocket hub. Runs on its own asyncio loop in a dedicated thread.
# --------------------------------------------------------------------------

class WSHub:
    def __init__(self, store: Store, token):
        self.store = store
        self.token = token
        self.queues: dict[str, asyncio.Queue] = {}
        self.loop: asyncio.AbstractEventLoop | None = None

    def push(self, device_id: str, envelope: dict) -> bool:
        """Called from any thread. Returns True if a subscriber received the
        envelope (so the durable queue can skip it)."""
        if not self.loop:
            return False
        q = self.queues.get(device_id)
        if not q:
            return False
        asyncio.run_coroutine_threadsafe(q.put(envelope), self.loop)
        return True

    async def _handler(self, websocket):
        device_id = None
        queue: asyncio.Queue | None = None
        try:
            try:
                raw = await asyncio.wait_for(websocket.recv(), timeout=10)
            except asyncio.TimeoutError:
                return
            try:
                auth = json.loads(raw)
            except json.JSONDecodeError:
                return
            if auth.get("type") != "auth":
                await websocket.send(json.dumps({"type": "error", "error": "auth required"}))
                return
            if self.token and auth.get("token") != self.token:
                await websocket.send(json.dumps({"type": "error", "error": "unauthorized"}))
                return
            device_id = str(auth.get("id") or "")
            if not device_id:
                await websocket.send(json.dumps({"type": "error", "error": "id required"}))
                return

            self.store.upsert_device(device_id, {
                "role": auth.get("role"),
                "name": auth.get("name"),
                "version": auth.get("version"),
                "transport": "ws",
            })

            queue = asyncio.Queue()
            self.queues[device_id] = queue

            for env in self.store.pop_messages(device_id):
                await queue.put(env)

            await websocket.send(json.dumps({"type": "ready"}))

            async def reader():
                async for inbound in websocket:
                    try:
                        m = json.loads(inbound)
                    except json.JSONDecodeError:
                        continue
                    t = m.get("type")
                    if t == "ping":
                        await websocket.send(json.dumps({"type": "pong"}))
                    elif t == "send":
                        target = str(m.get("to") or "")
                        body = m.get("msg") or {}
                        if isinstance(body, dict) and target:
                            body.setdefault("from", device_id)
                            self.store.push_message(target, body)
                    elif t == "heartbeat":
                        self.store.upsert_device(device_id, {
                            "metrics": m.get("metrics") or {},
                        })

            async def writer():
                while True:
                    env = await queue.get()
                    await websocket.send(json.dumps({"type": "message", "envelope": env}))

            done, pending = await asyncio.wait(
                [asyncio.create_task(reader()), asyncio.create_task(writer())],
                return_when=asyncio.FIRST_COMPLETED,
            )
            # Drain results so asyncio doesn't log "exception was never
            # retrieved" for the expected client-side disconnect.
            import websockets as _ws_mod
            for t in done:
                try:
                    t.result()
                except (_ws_mod.ConnectionClosed, asyncio.CancelledError):
                    pass
                except Exception as exc:
                    print(f"[ws] task error: {exc}", flush=True)
            for t in pending:
                t.cancel()
            for t in pending:
                try:
                    await t
                except (_ws_mod.ConnectionClosed, asyncio.CancelledError):
                    pass
                except Exception:
                    pass
        except Exception as exc:
            print(f"[ws] error: {exc}", flush=True)
        finally:
            if device_id and self.queues.get(device_id) is queue:
                self.queues.pop(device_id, None)

    async def _serve(self, host, ports, cert, key):
        import websockets

        servers = []
        servers.append(await websockets.serve(self._handler, host, ports[0]))
        print(f"[unison] WS    :{ports[0]} -> /ws", flush=True)
        if ports[1] is not None and cert and key and os.path.isfile(cert):
            try:
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                ctx.load_cert_chain(certfile=cert, keyfile=key)
                servers.append(await websockets.serve(
                    self._handler, host, ports[1], ssl=ctx))
                print(f"[unison] WSS   :{ports[1]} -> /ws", flush=True)
            except Exception as exc:
                print(f"[unison] WSS disabled: cert load failed ({exc})", flush=True)
        await asyncio.Future()  # run forever

    def start(self, host, ws_port, wss_port, cert, key):
        def run():
            self.loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self.loop)
            try:
                self.loop.run_until_complete(
                    self._serve(host, (ws_port, wss_port), cert, key))
            except Exception as exc:
                print(f"[ws] hub stopped: {exc}", flush=True)
        t = threading.Thread(target=run, daemon=True)
        t.start()
        # Wire push hook so HTTP push_message also delivers via WS.
        self.store.push_hook = self.push
        return t


# --------------------------------------------------------------------------
# HTTP / HTTPS handlers (file server + JSON API).
# --------------------------------------------------------------------------

class Handler(http.server.SimpleHTTPRequestHandler):
    server_version = "UnisonOS-Server/1.2"
    store: "Store | None" = None
    api_token: "str | None" = None
    atlas = None    # AtlasStore, set by _make_handler

    def _send_json(self, status: int, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        raw = self.rfile.read(n)
        try:
            return json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    def _check_auth(self) -> bool:
        if not self.api_token:
            return True
        h = self.headers.get("Authorization", "")
        if h.startswith("Bearer "):
            return h[7:].strip() == self.api_token
        return False

    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def log_message(self, format, *args):  # noqa: A002
        sys.stdout.write("[%s] %s - %s\n" % (
            self.log_date_time_string(), self.address_string(), format % args))
        sys.stdout.flush()

    def _handle_api(self, method: str, path: str) -> bool:
        if not path.startswith("/api/"):
            return False
        if not self._check_auth():
            self._send_json(401, {"error": "unauthorized"})
            return True
        if self.store is None:
            self._send_json(500, {"error": "store not initialised"})
            return True
        store = self.store

        url = urlparse(path)
        parts = url.path.split("/")
        seg = parts[2] if len(parts) >= 3 else ""

        try:
            if method == "POST" and seg == "register":
                body = self._read_body() or {}
                dev_id = body.get("id") or body.get("device_id")
                if not dev_id:
                    return self._send_json(400, {"error": "id required"}) or True
                rec = store.upsert_device(str(dev_id), {
                    "role": body.get("role"),
                    "name": body.get("name"),
                    "version": body.get("version"),
                    "registered_at": body.get("registered_at") or _now_ms(),
                })
                return self._send_json(200, {"ok": True, "device": rec}) or True

            if method == "POST" and seg == "heartbeat":
                body = self._read_body() or {}
                dev_id = body.get("id") or body.get("device_id")
                if not dev_id:
                    return self._send_json(400, {"error": "id required"}) or True
                rec = store.upsert_device(str(dev_id), {
                    "metrics": body.get("metrics") or {},
                    "version": body.get("version"),
                })
                return self._send_json(200, {"ok": True, "device": rec}) or True

            if method == "GET" and seg == "devices":
                return self._send_json(200, store.devices()) or True

            if seg == "messages" and len(parts) >= 4:
                dev_id = parts[3]
                if method == "GET":
                    msgs = store.pop_messages(dev_id)
                    return self._send_json(200, {"messages": msgs}) or True
                if method == "POST":
                    body = self._read_body() or {}
                    if not isinstance(body, dict):
                        return self._send_json(400, {"error": "json object required"}) or True
                    env = store.push_message(dev_id, body)
                    return self._send_json(200, {"ok": True, "message": env}) or True

            if method == "POST" and seg == "purge":
                # /api/purge        -> clear every device's durable queue
                # /api/purge/<id>   -> clear just that device
                if len(parts) >= 4 and parts[3]:
                    n = store.purge_queue(parts[3])
                    return self._send_json(200, {"ok": True, "dropped": n}) or True
                n = store.purge_all_queues()
                return self._send_json(200, {"ok": True, "dropped": n}) or True

            if method == "POST" and seg == "broadcast":
                body = self._read_body() or {}
                if not isinstance(body, dict):
                    return self._send_json(400, {"error": "json object required"}) or True
                envs = []
                for dev_id in store.devices().keys():
                    envs.append(store.push_message(dev_id, body))
                return self._send_json(200, {"ok": True, "delivered": len(envs)}) or True

            # ---- atlas: shared world map ------------------------------
            if seg == "atlas" and self.atlas is not None:
                sub = parts[3] if len(parts) >= 4 else ""
                if method == "POST" and sub == "blocks":
                    body = self._read_body() or {}
                    if not isinstance(body, dict):
                        return self._send_json(400, {"error": "json object required"}) or True
                    n = self.atlas.upsert_blocks(body.get("blocks") or [], body.get("by"))
                    return self._send_json(200, {"ok": True, "ingested": n}) or True
                if method == "GET" and sub == "blocks":
                    qs = parse_qs(url.query)
                    bbox = None
                    if "bbox" in qs:
                        try:
                            parts2 = [int(v) for v in qs["bbox"][0].split(",")]
                            if len(parts2) == 6:
                                bbox = tuple(parts2)
                        except ValueError:
                            pass
                    kinds = qs.get("kinds", [None])[0]
                    kinds_list = kinds.split(",") if kinds else None
                    name = qs.get("name", [None])[0]
                    limit = int(qs.get("limit", ["10000"])[0] or "10000")
                    rows = self.atlas.query_blocks(
                        bbox=bbox, kinds=kinds_list, name=name, limit=limit)
                    return self._send_json(200, {"blocks": rows}) or True
                if method == "GET" and sub == "stats":
                    return self._send_json(200, self.atlas.stats()) or True
                if method == "GET" and sub == "landmarks":
                    return self._send_json(200, {"items": list(self.atlas.landmarks().values())}) or True
                if method == "POST" and sub == "landmarks":
                    body = self._read_body() or {}
                    nm = body.get("name")
                    if not nm:
                        return self._send_json(400, {"error": "name required"}) or True
                    rec = self.atlas.add_landmark(
                        str(nm), int(body.get("x") or 0), int(body.get("y") or 0),
                        int(body.get("z") or 0),
                        tags=body.get("tags") or [], by=body.get("by"))
                    return self._send_json(200, {"ok": True, "landmark": rec}) or True
                if method == "DELETE" and sub == "landmarks" and len(parts) >= 5:
                    ok = self.atlas.remove_landmark(parts[4])
                    return self._send_json(200, {"ok": ok}) or True
                if method == "POST" and sub == "events":
                    body = self._read_body() or {}
                    n = self.atlas.push_events(body.get("events") or [], body.get("by"))
                    return self._send_json(200, {"ok": True, "ingested": n}) or True
                if method == "GET" and sub == "events":
                    qs = parse_qs(url.query)
                    since = int(qs.get("since", ["0"])[0] or "0")
                    limit = int(qs.get("limit", ["500"])[0] or "500")
                    return self._send_json(200, {"events": self.atlas.recent_events(since, limit)}) or True
                if method == "POST" and sub == "storage":
                    body = self._read_body() or {}
                    dev = str(body.get("by") or body.get("device") or "")
                    if not dev:
                        return self._send_json(400, {"error": "by required"}) or True
                    n = self.atlas.replace_storage(dev, body.get("items") or [])
                    return self._send_json(200, {"ok": True, "rows": n}) or True
                if method == "GET" and sub == "storage":
                    qs = parse_qs(url.query)
                    name = qs.get("name", [None])[0]
                    device = qs.get("device", [None])[0]
                    pattern = qs.get("pattern", [None])[0]
                    return self._send_json(200,
                        self.atlas.storage_items(name=name, device=device,
                                                 pattern=pattern)) or True
                if method == "GET" and sub == "path":
                    qs = parse_qs(url.query)
                    try:
                        fr = tuple(int(v) for v in qs.get("from", [""])[0].split(","))
                        to = tuple(int(v) for v in qs.get("to", [""])[0].split(","))
                    except ValueError:
                        return self._send_json(400, {"error": "from/to required as x,y,z"}) or True
                    if len(fr) != 3 or len(to) != 3:
                        return self._send_json(400, {"error": "from/to need 3 ints"}) or True
                    path = self.atlas.find_path(fr, to)
                    if not path:
                        return self._send_json(404, {"error": "no path"}) or True
                    return self._send_json(200, {
                        "path": [{"x": p[0], "y": p[1], "z": p[2]} for p in path],
                        "length": len(path),
                    }) or True

            self._send_json(404, {"error": "no such endpoint"})
            return True
        except Exception as exc:
            self._send_json(500, {"error": str(exc)})
            return True

    def do_GET(self):
        url = urlparse(self.path)
        if self._handle_api("GET", url.path):
            return
        super().do_GET()

    def do_POST(self):
        url = urlparse(self.path)
        if self._handle_api("POST", url.path):
            return
        self.send_response(405)
        self.send_header("Allow", "GET, HEAD")
        self.end_headers()


class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def _make_handler(root: str, store: Store, token, atlas=None):
    Handler.store = store
    Handler.api_token = token
    Handler.atlas = atlas
    return partial(Handler, directory=root)


def _serve_plain(root, store, token, port, atlas=None):
    srv = ThreadingHTTPServer(("0.0.0.0", port), _make_handler(root, store, token, atlas))
    print(f"[unison] HTTP  :{port} -> {root}", flush=True)
    srv.serve_forever()


def _serve_tls(root, store, token, port, cert, key, atlas=None):
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=cert, keyfile=key)
    except Exception as exc:
        print(f"[unison] HTTPS disabled: cert load failed ({exc})", flush=True)
        return
    srv = ThreadingHTTPServer(("0.0.0.0", port), _make_handler(root, store, token, atlas))
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"[unison] HTTPS :{port} -> {root}", flush=True)
    srv.serve_forever()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--root",     default=os.environ.get("UNISON_ROOT", "/srv/unison"))
    p.add_argument("--state",    default=os.environ.get("UNISON_STATE", STATE_DIR_DEFAULT))
    p.add_argument("--http",     type=int, default=int(os.environ.get("UNISON_HTTP_PORT",  "9273")))
    p.add_argument("--https",    type=int, default=int(os.environ.get("UNISON_HTTPS_PORT", "9274")))
    p.add_argument("--ws",       type=int, default=int(os.environ.get("UNISON_WS_PORT",  "9275")))
    p.add_argument("--wss",      type=int, default=int(os.environ.get("UNISON_WSS_PORT", "9276")))
    p.add_argument("--cert",     default=os.environ.get("UNISON_CERT", "/etc/unison/server.crt"))
    p.add_argument("--key",      default=os.environ.get("UNISON_KEY",  "/etc/unison/server.key"))
    p.add_argument("--token-file", default=os.environ.get("UNISON_API_TOKEN_FILE", TOKEN_FILE_DEFAULT))
    p.add_argument("--no-tls",   action="store_true")
    p.add_argument("--no-ws",    action="store_true")
    args = p.parse_args()

    if not os.path.isdir(args.root):
        os.makedirs(args.root, exist_ok=True)

    store = Store(args.state)

    # Atlas: shared world map. Sits next to /api/messages on the same
    # ports. Loads lazily so the server still runs if atlas_store fails.
    atlas = None
    try:
        from atlas_store import AtlasStore
        atlas = AtlasStore(os.path.join(args.state, "atlas"))
        print(f"[unison] atlas:  {os.path.join(args.state, 'atlas')}", flush=True)
    except Exception as exc:
        print(f"[unison] atlas disabled: {exc}", flush=True)

    token = None
    if os.path.isfile(args.token_file):
        with open(args.token_file, "r") as fh:
            token = fh.read().strip() or None

    if token:
        print(f"[unison] auth: required (token from {args.token_file})", flush=True)
    else:
        print(f"[unison] auth: DISABLED (no token at {args.token_file})", flush=True)

    threads = [threading.Thread(
        target=_serve_plain,
        args=(args.root, store, token, args.http, atlas),
        daemon=True)]

    if not args.no_tls:
        if os.path.isfile(args.cert) and os.path.isfile(args.key):
            threads.append(threading.Thread(
                target=_serve_tls,
                args=(args.root, store, token, args.https, args.cert, args.key, atlas),
                daemon=True))
        else:
            print(f"[unison] cert/key missing; HTTPS disabled", flush=True)

    if not args.no_ws:
        try:
            import websockets  # noqa: F401
            hub = WSHub(store, token)
            hub.start("0.0.0.0", args.ws, args.wss, args.cert, args.key)
        except ImportError:
            print(f"[unison] python3-websockets not installed; WS disabled", flush=True)

    for t in threads:
        t.start()
    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        print("[unison] shutting down", flush=True)


if __name__ == "__main__":
    main()
