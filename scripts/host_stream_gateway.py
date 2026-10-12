"""Loopback-only EpicVM launch redemption and Moonlight forward-auth service."""

from __future__ import annotations

import argparse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from http.cookies import SimpleCookie
from pathlib import Path
import sqlite3
import sys
import time
import threading
from urllib import request, error
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dashboard"))
from direct_stream_auth import ROUTE_RE, issue_session, verify_grant, verify_session  # noqa: E402


class Gateway(ThreadingHTTPServer):
    # The stream page requests many modules at once. Windows rejects excess
    # connections when the default five-connection accept backlog fills.
    request_queue_size = 256
    daemon_threads = True

    def __init__(self, address, *, key_path: Path, routes_path: Path, nonces_path: Path,
                 authority=None, disconnect=None):
        super().__init__(address, GatewayHandler)
        self.key = key_path.read_bytes()
        if len(self.key) < 32:
            raise ValueError("Stream signing key is too short")
        self.routes_path = routes_path
        self.nonces_path = nonces_path
        self.authority = authority
        self.disconnect = disconnect
        self.sessions = {}
        self.sessions_lock = threading.Lock()
        self.validation_lock = threading.Lock()
        self.validated = {}
        self.monitor_stop = threading.Event()
        self.connections = {}
        with sqlite3.connect(nonces_path) as db:
            db.execute("CREATE TABLE IF NOT EXISTS used_grants (jti TEXT PRIMARY KEY, expires INTEGER NOT NULL)")
            db.execute('CREATE TABLE IF NOT EXISTS stream_sessions (token TEXT PRIMARY KEY, route TEXT NOT NULL)')
            if 'connection' not in {row[1] for row in db.execute('PRAGMA table_info(stream_sessions)')}:
                db.execute("ALTER TABLE stream_sessions ADD COLUMN connection TEXT NOT NULL DEFAULT ''")
            self.sessions = dict(db.execute('SELECT token, route FROM stream_sessions'))
            self.connections = dict(db.execute('SELECT token, connection FROM stream_sessions'))
        if authority:
            threading.Thread(target=self._monitor, daemon=True).start()

    def validate(self, route, token, *, fresh=False):
        if not self.authority:
            return True  # Explicit offline mode for isolated tests only.
        # Coalesce parallel static-module requests under a short lease. This
        # does not put a WAN request on the media/input path or each asset.
        with self.validation_lock:
            now = time.monotonic()
            if not fresh and self.validated.get((route, token), 0) > now:
                return True
            body = json.dumps({'route': route, 'token': token}).encode()
            try:
                with request.urlopen(request.Request(self.authority, data=body,
                                     headers={'Content-Type': 'application/json'}), timeout=3) as response:
                    valid = response.status == 204
            except (OSError, error.URLError):
                valid = False
            self.validated = {item: expiry for item, expiry in self.validated.items() if expiry > now}
            if valid and len(self.validated) < 1024:
                self.validated[(route, token)] = time.monotonic() + 2
            else:
                self.validated.pop((route, token), None)
            return valid

    def connection_allowed(self, connection):
        policy_path = self.routes_path.parent / 'hosting-policy.json'
        if not policy_path.exists():
            return True
        policy = json.loads(policy_path.read_text(encoding='utf-8-sig'))
        local = self.routes_path.parent / 'local-gateway.json'
        local_origin = json.loads(local.read_text(encoding='utf-8-sig')).get('origin', '') if local.exists() else ''
        is_local = connection.lower() == urlsplit(local_origin).netloc.lower() and bool(connection)
        return policy.get('localEnabled' if is_local else 'normalEnabled', True) is True

    def remember(self, route, token, connection=''):
        with self.sessions_lock:
            # One resource may have several browser sessions. Bound memory and
            # refuse further sessions rather than discard revocation tracking.
            if token not in self.sessions and len(self.sessions) >= 1024:
                return False
            if token not in self.sessions:
                with sqlite3.connect(self.nonces_path) as db:
                    db.execute('INSERT OR IGNORE INTO stream_sessions (token, route, connection) VALUES (?, ?, ?)', (token, route, connection))
            self.sessions[token] = route
            if self.connections.get(token) != connection:
                with sqlite3.connect(self.nonces_path) as db:
                    db.execute('UPDATE stream_sessions SET connection = ? WHERE token = ?', (connection, token))
            self.connections[token] = connection
        return True

    def check_sessions(self):
        with self.sessions_lock:
            sessions = list(self.sessions.items())
        denied = set()
        for token, route in sessions:
            try:
                verify_session(self.key, token, route=route)
                valid = self.route(route) and self.connection_allowed(self.connections.get(token, '')) and self.validate(route, token, fresh=True)
            except (OSError, ValueError):
                valid = False
            if not valid:
                denied.add(route)
        for route in denied:
            # Closing the host viewer ends its WebRTC transports, including
            # clients that ignore browser-side logout. Windows seats stay alive.
            if self.disconnect:
                self.disconnect(route)
            with self.sessions_lock:
                with sqlite3.connect(self.nonces_path) as db:
                    db.execute('DELETE FROM stream_sessions WHERE route = ?', (route,))
                self.sessions = {token: name for token, name in self.sessions.items() if name != route}
                self.connections = {token: channel for token, channel in self.connections.items() if token in self.sessions}

    def _monitor(self):
        while not self.monitor_stop.wait(5):
            try:
                self.check_sessions()
            except Exception:
                # Retain tracking and retry if transport teardown fails.
                pass

    def server_close(self):
        self.monitor_stop.set()
        super().server_close()

    def route(self, name: str) -> dict | None:
        if not ROUTE_RE.fullmatch(name):
            return None
        record = json.loads(self.routes_path.read_text(encoding="utf-8")).get(name)
        return record if isinstance(record, dict) and record.get("enabled") is True else None

    def redeem_once(self, grant: dict) -> bool:
        with sqlite3.connect(self.nonces_path) as db:
            db.execute("DELETE FROM used_grants WHERE expires < ?", (int(time.time()),))
            cursor = db.execute("INSERT OR IGNORE INTO used_grants VALUES (?,?)",
                                (grant["jti"], int(grant["exp"])))
            return cursor.rowcount == 1


class GatewayHandler(BaseHTTPRequestHandler):
    server: Gateway

    def log_message(self, fmt, *args):
        # Do not log launch grants, cookies, or the request URL.
        pass

    def _reply(self, code, body=b"", headers=()):
        self.send_response(code)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        endpoint = urlsplit(self.path).path
        if endpoint == "/health":
            self._reply(HTTPStatus.OK, b"ok")
            return
        if endpoint != "/authorize":
            self._reply(HTTPStatus.NOT_FOUND)
            return
        uri = self.headers.get("X-Forwarded-Uri", "")
        path = urlsplit(uri).path
        parts = path.split("/")
        if len(parts) < 4 or parts[1] != "EpicVM":
            self._reply(HTTPStatus.UNAUTHORIZED)
            return
        route = parts[2]
        record = self.server.route(route)
        if not record or not path.startswith(f"/EpicVM/{route}/"):
            self._reply(HTTPStatus.UNAUTHORIZED)
            return
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
            token = cookie[f"evs_{route}"].value
            verify_session(self.server.key, token, route=route)
            connection = self.headers.get('X-EpicVM-Connection', '')
            if not self.server.connection_allowed(connection) or not self.server.validate(route, token) or not self.server.remember(route, token, connection):
                raise ValueError('Revoked stream session')
        except (KeyError, ValueError):
            self._reply(HTTPStatus.UNAUTHORIZED)
            return
        self._reply(HTTPStatus.OK, headers=(("X-EpicVM-User", record["moonlightUser"]),))

    def do_POST(self):
        if self.path != "/redeem":
            self._reply(HTTPStatus.NOT_FOUND)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size < 1 or size > 4096:
                raise ValueError("Invalid grant size")
            body = self.rfile.read(size).decode("ascii")
            token = parse_qs(body, strict_parsing=True)["grant"][0]
            grant = verify_grant(self.server.key, token)
            if not self.server.route(grant["route"]) or not self.server.redeem_once(grant):
                raise ValueError("Unavailable or used stream grant")
            session = issue_session(self.server.key, grant)
            connection = self.headers.get('Host', '')
            if not self.server.connection_allowed(connection) or not self.server.validate(grant['route'], session) or not self.server.remember(grant['route'], session, connection):
                raise ValueError('Revoked stream grant')
        except (KeyError, UnicodeError, ValueError):
            self._reply(HTTPStatus.FORBIDDEN, b"Stream launch expired. Return to EpicVM and launch again.")
            return
        route = grant["route"]
        cookie = f"evs_{route}={session}; Path=/EpicVM/{route}/; Secure; HttpOnly; SameSite=Lax"
        self._reply(HTTPStatus.SEE_OTHER, headers=(("Set-Cookie", cookie), ("Location", grant["path"])))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--key", required=True, type=Path)
    parser.add_argument("--routes", required=True, type=Path)
    parser.add_argument("--nonces", required=True, type=Path)
    parser.add_argument("--port", default=8090, type=int)
    parser.add_argument('--authority', default='https://techexplore.us/EpicVM/api/stream/validate')
    args = parser.parse_args()
    def disconnect(route):
        import psutil
        target = (args.routes.parent / route).resolve()
        for process in psutil.process_iter(['name']):
            try:
                if (process.info['name'].lower() == 'web-server.exe'
                        and Path(process.cwd()).resolve() == target):
                    process.terminate()
                    process.wait(timeout=3)
            except psutil.NoSuchProcess:
                continue
    Gateway(("127.0.0.1", args.port), key_path=args.key, routes_path=args.routes,
            nonces_path=args.nonces, authority=args.authority, disconnect=disconnect).serve_forever()
