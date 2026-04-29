#!/usr/bin/env python3
"""
UnisonOS package + OS mirror server.

Serves the contents of $UNISON_ROOT (default /srv/unison) over plain HTTP and
TLS simultaneously, on the ports specified by --http and --https.

Usage:
    serve.py --root /srv/unison --http 9273 --https 9274 \
             --cert /etc/unison/server.crt --key /etc/unison/server.key
"""

from __future__ import annotations

import argparse
import http.server
import os
import ssl
import sys
import threading
from functools import partial


class UnisonHandler(http.server.SimpleHTTPRequestHandler):
    server_version = "UnisonOS-Repo/1.0"

    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def log_message(self, format, *args):  # noqa: A002 - signature dictated by base class
        sys.stdout.write("[%s] %s - %s\n" % (
            self.log_date_time_string(),
            self.address_string(),
            format % args,
        ))
        sys.stdout.flush()


class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def _make_handler(root: str):
    return partial(UnisonHandler, directory=root)


def _serve_plain(root: str, port: int):
    srv = ThreadingHTTPServer(("0.0.0.0", port), _make_handler(root))
    print(f"[unison] HTTP  listening on :{port} -> {root}", flush=True)
    srv.serve_forever()


def _serve_tls(root: str, port: int, cert: str, key: str):
    srv = ThreadingHTTPServer(("0.0.0.0", port), _make_handler(root))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=cert, keyfile=key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"[unison] HTTPS listening on :{port} -> {root}", flush=True)
    srv.serve_forever()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--root",  default=os.environ.get("UNISON_ROOT", "/srv/unison"))
    p.add_argument("--http",  type=int, default=int(os.environ.get("UNISON_HTTP_PORT",  "9273")))
    p.add_argument("--https", type=int, default=int(os.environ.get("UNISON_HTTPS_PORT", "9274")))
    p.add_argument("--cert",  default=os.environ.get("UNISON_CERT", "/etc/unison/server.crt"))
    p.add_argument("--key",   default=os.environ.get("UNISON_KEY",  "/etc/unison/server.key"))
    p.add_argument("--no-tls", action="store_true",
                   help="skip the HTTPS listener (useful if you don't have a cert yet)")
    args = p.parse_args()

    if not os.path.isdir(args.root):
        print(f"[unison] root '{args.root}' does not exist; creating", flush=True)
        os.makedirs(args.root, exist_ok=True)

    threads = []
    threads.append(threading.Thread(target=_serve_plain,
                                    args=(args.root, args.http),
                                    daemon=True))

    if not args.no_tls:
        if not (os.path.isfile(args.cert) and os.path.isfile(args.key)):
            print(f"[unison] WARNING: cert or key missing ({args.cert} / {args.key}); skipping HTTPS",
                  flush=True)
        else:
            threads.append(threading.Thread(target=_serve_tls,
                                            args=(args.root, args.https, args.cert, args.key),
                                            daemon=True))

    for t in threads:
        t.start()

    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        print("[unison] shutting down", flush=True)


if __name__ == "__main__":
    main()
