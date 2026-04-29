#!/usr/bin/env python3
"""
UnisonOS package server + device message bus.

* Static file server for /srv/unison (unchanged behaviour: HTTP on 9273,
  HTTPS on 9274).
* JSON API at /api/* providing:
    POST /api/register                     register a device
    POST /api/heartbeat                    heartbeat + metric upload
    GET  /api/devices                      list registered devices
    GET  /api/messages/<device>            pop queued messages for a device
    POST /api/messages/<device>            queue a message for a device
    POST /api/broadcast                    queue a message for every device

  All API calls require `Authorization: Bearer <api_token>` whose value
  matches /etc/unison/api.token (sibling of the cloudflare token).

State (devices, queues) lives in /srv/unison.state/ as JSON files.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import ssl
import sys
import threading
import time
import uuid
from functools import partial
from urllib.parse import urlparse


STATE_DIR_DEFAULT = "/srv/unison.state"
TOKEN_FILE_DEFAULT = "/etc/unison/api.token"


def _now_ms() -> int:
    return int(time.time() * 1000)


class Store:
    """Tiny JSON-file store. One lock for the whole server, fine at our scale."""

    def __init__(self, root: str):
        self.root = root
        self.devices_path = os.path.join(root, "devices.json")
        self.queues_dir = os.path.join(root, "queues")
        self.lock = threading.Lock()
        os.makedirs(root, exist_ok=True)
        os.makedirs(self.queues_dir, exist_ok=True)
        if not os.path.isfile(self.devices_path):
            self._write(self.devices_path, {})

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

    def devices(self) -> dict:
        with self.lock:
            return self._read(self.devices_path) or {}

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
        with self.lock:
            path = self.queue_path(device_id)
            queue = self._read(path) or []
            envelope = {
                "id": str(uuid.uuid4()),
                "ts": _now_ms(),
                "to": device_id,
                "msg": msg,
            }
            queue.append(envelope)
            self._write(path, queue)
            return envelope

    def pop_messages(self, device_id: str, max_count: int = 64):
        with self.lock:
            path = self.queue_path(device_id)
            queue = self._read(path) or []
            taken = queue[:max_count]
            remaining = queue[max_count:]
            self._write(path, remaining)
            return taken


class Handler(http.server.SimpleHTTPRequestHandler):
    server_version = "UnisonOS-Server/1.1"
    store: "Store | None" = None        # set by factory
    api_token: "str | None" = None      # set by factory

    # ---- helpers -----------------------------------------------------------

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
            return True   # auth disabled
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

    # ---- API dispatch ------------------------------------------------------

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

        parts = path.split("/")
        # /api/<segment>/...
        if len(parts) >= 3:
            seg = parts[2]
        else:
            seg = ""

        try:
            if method == "POST" and seg == "register":
                body = self._read_body() or {}
                dev_id = body.get("id") or body.get("device_id")
                if not dev_id:
                    return self._send_json(400, {"error": "id required"}) or True
                rec = store.upsert_device(str(dev_id), {
                    "role":      body.get("role"),
                    "name":      body.get("name"),
                    "version":   body.get("version"),
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

            if method == "POST" and seg == "broadcast":
                body = self._read_body() or {}
                if not isinstance(body, dict):
                    return self._send_json(400, {"error": "json object required"}) or True
                envs = []
                for dev_id in store.devices().keys():
                    envs.append(store.push_message(dev_id, body))
                return self._send_json(200, {"ok": True, "delivered": len(envs)}) or True

            self._send_json(404, {"error": "no such endpoint"})
            return True
        except Exception as exc:  # pragma: no cover
            self._send_json(500, {"error": str(exc)})
            return True

    # ---- entry points ------------------------------------------------------

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


def _make_handler(root: str, store: Store, token):
    Handler.store = store
    Handler.api_token = token
    return partial(Handler, directory=root)


def _serve_plain(root, store, token, port):
    srv = ThreadingHTTPServer(("0.0.0.0", port), _make_handler(root, store, token))
    print(f"[unison] HTTP  :{port} -> {root}", flush=True)
    srv.serve_forever()


def _serve_tls(root, store, token, port, cert, key):
    srv = ThreadingHTTPServer(("0.0.0.0", port), _make_handler(root, store, token))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=cert, keyfile=key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"[unison] HTTPS :{port} -> {root}", flush=True)
    srv.serve_forever()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--root",     default=os.environ.get("UNISON_ROOT", "/srv/unison"))
    p.add_argument("--state",    default=os.environ.get("UNISON_STATE", STATE_DIR_DEFAULT))
    p.add_argument("--http",     type=int, default=int(os.environ.get("UNISON_HTTP_PORT",  "9273")))
    p.add_argument("--https",    type=int, default=int(os.environ.get("UNISON_HTTPS_PORT", "9274")))
    p.add_argument("--cert",     default=os.environ.get("UNISON_CERT", "/etc/unison/server.crt"))
    p.add_argument("--key",      default=os.environ.get("UNISON_KEY",  "/etc/unison/server.key"))
    p.add_argument("--token-file", default=os.environ.get("UNISON_API_TOKEN_FILE", TOKEN_FILE_DEFAULT))
    p.add_argument("--no-tls", action="store_true")
    args = p.parse_args()

    if not os.path.isdir(args.root):
        os.makedirs(args.root, exist_ok=True)

    store = Store(args.state)

    token = None
    if os.path.isfile(args.token_file):
        with open(args.token_file, "r") as fh:
            token = fh.read().strip() or None

    if token:
        print(f"[unison] API auth: required (token from {args.token_file})", flush=True)
    else:
        print(f"[unison] API auth: DISABLED (no token at {args.token_file})", flush=True)

    threads = [threading.Thread(
        target=_serve_plain,
        args=(args.root, store, token, args.http),
        daemon=True)]

    if not args.no_tls:
        if os.path.isfile(args.cert) and os.path.isfile(args.key):
            threads.append(threading.Thread(
                target=_serve_tls,
                args=(args.root, store, token, args.https, args.cert, args.key),
                daemon=True))
        else:
            print(f"[unison] cert/key missing; HTTPS disabled", flush=True)

    for t in threads:
        t.start()
    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        print("[unison] shutting down", flush=True)


if __name__ == "__main__":
    main()
